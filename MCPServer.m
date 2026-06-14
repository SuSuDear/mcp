#import "MCPServer.h"
#import "MCPProcessUtil.h"
#import <UIKit/UIKit.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>
#import <stdlib.h>
#import <sys/utsname.h>
#import <sys/statvfs.h>
#import <sys/wait.h>
#import <mach/mach.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#define MCP_PROTOCOL_VERSION @"2025-03-26"
#define MCP_SERVER_NAME      @"com.susu.mcp"
#define MCP_SERVER_VERSION   @"1.1.1"
#define HTTP_BUF_SIZE        (256 * 1024)
#define MCP_MAX_CHUNK_LINE   (8 * 1024)
#define MCP_LOG(fmt, ...)    NSLog(@"[susu][mcp] " fmt, ##__VA_ARGS__)

static BOOL MCPNumberFromArgs(NSDictionary *args, NSString *key, double defaultValue, BOOL required, double *outValue, NSString **outError) {
    id value = args[key];
    if (!value || value == [NSNull null]) {
        if (required) {
            if (outError) *outError = [NSString stringWithFormat:@"Missing required parameter: %@", key];
            return NO;
        }
        if (outValue) *outValue = defaultValue;
        return YES;
    }

    if ([value isKindOfClass:[NSNumber class]]) {
        if (outValue) *outValue = [value doubleValue];
        return YES;
    }

    if ([value isKindOfClass:[NSString class]]) {
        NSScanner *scanner = [NSScanner scannerWithString:(NSString *)value];
        double parsed = 0;
        if ([scanner scanDouble:&parsed] && scanner.isAtEnd) {
            if (outValue) *outValue = parsed;
            return YES;
        }
    }

    if (outError) *outError = [NSString stringWithFormat:@"Invalid parameter %@: expected number", key];
    return NO;
}

static BOOL MCPStringFromArgs(NSDictionary *args, NSString *key, BOOL required, NSString **outValue, NSString **outError) {
    id value = args[key];
    if (!value || value == [NSNull null]) {
        if (required) {
            if (outError) *outError = [NSString stringWithFormat:@"Missing required parameter: %@", key];
            return NO;
        }
        if (outValue) *outValue = nil;
        return YES;
    }

    if ([value isKindOfClass:[NSString class]]) {
        if (outValue) *outValue = value;
        return YES;
    }

    if (outError) *outError = [NSString stringWithFormat:@"Invalid parameter %@: expected string", key];
    return NO;
}

static BOOL MCPBoolFromArgs(NSDictionary *args, NSString *key, BOOL defaultValue, BOOL *outValue, NSString **outError) {
    id value = args[key];
    if (!value || value == [NSNull null]) {
        if (outValue) *outValue = defaultValue;
        return YES;
    }

    if ([value isKindOfClass:[NSNumber class]]) {
        if (outValue) *outValue = [value boolValue];
        return YES;
    }

    if ([value isKindOfClass:[NSString class]]) {
        NSString *lower = [(NSString *)value lowercaseString];
        if ([lower isEqualToString:@"true"] || [lower isEqualToString:@"yes"] || [lower isEqualToString:@"1"]) {
            if (outValue) *outValue = YES;
            return YES;
        }
        if ([lower isEqualToString:@"false"] || [lower isEqualToString:@"no"] || [lower isEqualToString:@"0"]) {
            if (outValue) *outValue = NO;
            return YES;
        }
    }

    if (outError) *outError = [NSString stringWithFormat:@"Invalid parameter %@: expected boolean", key];
    return NO;
}


static NSInteger MCPIntegerFromArgs(NSDictionary *args, NSString *key, NSInteger defaultValue) {
    id value = args[key];
    if ([value isKindOfClass:[NSNumber class]]) return [value integerValue];
    if ([value isKindOfClass:[NSString class]]) return [(NSString *)value integerValue];
    return defaultValue;
}

static NSString *MCPResolvedToolPath(NSString *path) {
    if (path.length == 0) return [[NSFileManager defaultManager] currentDirectoryPath];
    NSString *expanded = [path stringByExpandingTildeInPath];
    if ([expanded isAbsolutePath]) return expanded;
    return [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:expanded].stringByStandardizingPath;
}

static NSString *MCPRelativePath(NSString *path, NSString *base) {
    if (base.length == 0 || ![path hasPrefix:base]) return path;
    NSString *relative = [path substringFromIndex:base.length];
    if ([relative hasPrefix:@"/"]) relative = [relative substringFromIndex:1];
    return relative.length > 0 ? relative : @".";
}


static NSString *MCPJSONString(NSDictionary *dict) {
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
    return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding] ?: @"{}";
}

static NSString *MCPFileTypeFromAttributes(NSDictionary *attrs, BOOL isDir) {
    NSString *type = attrs[NSFileType];
    if ([type isEqualToString:NSFileTypeSymbolicLink]) return @"symlink";
    if ([type isEqualToString:NSFileTypeSocket]) return @"socket";
    if ([type isEqualToString:@"NSFileTypeFifo"]) return @"fifo";
    if ([type isEqualToString:NSFileTypeCharacterSpecial] || [type isEqualToString:NSFileTypeBlockSpecial]) return @"device";
    if (isDir) return @"directory";
    if ([type isEqualToString:NSFileTypeRegular]) return @"file";
    return @"unsupported";
}

static BOOL MCPDataLooksBinary(NSData *data) {
    if (!data.length) return NO;
    const uint8_t *bytes = data.bytes;
    NSUInteger limit = MIN(data.length, (NSUInteger)8192);
    for (NSUInteger i = 0; i < limit; i++) {
        if (bytes[i] == 0) return YES;
    }
    return NO;
}

static BOOL MCPSearchShouldSkipDirectory(NSString *name) {
    static NSSet *skip = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        skip = [NSSet setWithArray:@[@".git", @"node_modules", @"Pods", @"build", @"DerivedData", @"dist", @".cache"]];
    });
    return [skip containsObject:name];
}

static BOOL MCPSearchShouldSkipExtension(NSString *path) {
    NSString *ext = path.pathExtension.lowercaseString;
    if (!ext.length) return NO;
    static NSSet *skip = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        skip = [NSSet setWithArray:@[@"png", @"jpg", @"jpeg", @"gif", @"webp", @"heic", @"pdf", @"zip", @"gz", @"tgz", @"xz", @"7z", @"dylib", @"a", @"o", @"so", @"sqlite", @"db", @"car", @"ttf", @"otf", @"mp3", @"mp4", @"mov"]];
    });
    return [skip containsObject:ext];
}

static NSString *MCPBasePath(NSString *path) {
    if (!path.length) return @"";
    NSRange query = [path rangeOfString:@"?"];
    if (query.location == NSNotFound) return path;
    return [path substringToIndex:query.location];
}

static BOOL MCPWriteAllToFD(int fd, const void *bytes, size_t length) {
    const uint8_t *cursor = bytes;
    size_t remaining = length;
    while (remaining > 0) {
        ssize_t written = write(fd, cursor, remaining);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return NO;
        cursor += written;
        remaining -= (size_t)written;
    }
    return YES;
}

static NSRange MCPFindCRLF(NSData *data, NSUInteger offset) {
    const uint8_t *bytes = data.bytes;
    NSUInteger length = data.length;
    if (!bytes || offset >= length) {
        return NSMakeRange(NSNotFound, 0);
    }

    for (NSUInteger i = offset; i + 1 < length; i++) {
        if (bytes[i] == '\r' && bytes[i + 1] == '\n') {
            return NSMakeRange(i, 2);
        }
    }
    return NSMakeRange(NSNotFound, 0);
}

static BOOL MCPParseHTTPChunkSize(NSData *lineData, unsigned long long *outSize) {
    NSString *line = [[NSString alloc] initWithData:lineData encoding:NSASCIIStringEncoding];
    if (line.length == 0) {
        return NO;
    }

    NSString *sizePart = [line componentsSeparatedByString:@";"].firstObject;
    sizePart = [sizePart stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (sizePart.length == 0) {
        return NO;
    }

    const char *sizeCString = sizePart.UTF8String;
    if (!sizeCString || sizeCString[0] == '\0') {
        return NO;
    }

    errno = 0;
    char *end = NULL;
    unsigned long long size = strtoull(sizeCString, &end, 16);
    if (errno != 0 || end == sizeCString || (end && *end != '\0')) {
        return NO;
    }

    if (outSize) {
        *outSize = size;
    }
    return YES;
}

static void MCPSetHTTPBodyError(int *errorStatus, NSString **errorMessage, int status, NSString *message) {
    if (errorStatus) {
        *errorStatus = status;
    }
    if (errorMessage) {
        *errorMessage = message;
    }
}

static void MCPAddWhitelistedKeys(NSMutableDictionary *destination, NSDictionary *source, NSArray<NSString *> *keys) {
    if (![destination isKindOfClass:[NSMutableDictionary class]] ||
        ![source isKindOfClass:[NSDictionary class]] ||
        ![keys isKindOfClass:[NSArray class]]) {
        return;
    }

    for (NSString *key in keys) {
        id value = source[key];
        if (value && value != [NSNull null]) {
            destination[key] = value;
        }
    }
}

static BOOL MCPRectValuesFromDictionary(NSDictionary *rect, double *outX, double *outY, double *outWidth, double *outHeight) {
    if (![rect isKindOfClass:[NSDictionary class]]) {
        return NO;
    }

    id xValue = rect[@"x"] ?: rect[@"X"];
    id yValue = rect[@"y"] ?: rect[@"Y"];
    id widthValue = rect[@"width"] ?: rect[@"Width"];
    id heightValue = rect[@"height"] ?: rect[@"Height"];
    if (![xValue respondsToSelector:@selector(doubleValue)] ||
        ![yValue respondsToSelector:@selector(doubleValue)] ||
        ![widthValue respondsToSelector:@selector(doubleValue)] ||
        ![heightValue respondsToSelector:@selector(doubleValue)]) {
        return NO;
    }

    double x = [xValue doubleValue];
    double y = [yValue doubleValue];
    double width = [widthValue doubleValue];
    double height = [heightValue doubleValue];
    if (!isfinite(x) || !isfinite(y) || !isfinite(width) || !isfinite(height) || width <= 0.0 || height <= 0.0) {
        return NO;
    }

    if (outX) *outX = x;
    if (outY) *outY = y;
    if (outWidth) *outWidth = width;
    if (outHeight) *outHeight = height;
    return YES;
}

static BOOL MCPDirectoryExists(NSString *path) {
    if (path.length == 0) return NO;
    BOOL isDirectory = NO;
    return [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory] && isDirectory;
}

static NSDictionary *MCPHelperExecutableStatus(NSString *logicalPath) {
    NSString *resolvedPath = MCPResolvedJailbreakPath(logicalPath);
    BOOL executable = resolvedPath.length > 0 && [[NSFileManager defaultManager] isExecutableFileAtPath:resolvedPath];
    return @{
        @"path": resolvedPath ?: @"",
        @"executable": @(executable)
    };
}

static NSDictionary *MCPJailbreakInfo(BOOL debug) {
    NSString *packageScheme = nil;
    NSString *packageArchitecture = nil;
#ifdef MCP_ROOTHIDE
    packageScheme = @"roothide";
    packageArchitecture = @"iphoneos-arm64e";
#elif defined(MCP_ROOTLESS)
    packageScheme = @"rootless";
    packageArchitecture = @"iphoneos-arm64";
#else
    packageScheme = @"rootful";
    packageArchitecture = @"iphoneos-arm";
#endif

    NSString *type = packageScheme;
    NSString *rootPath = @"/";
    if ([packageScheme isEqualToString:@"roothide"]) {
        NSString *candidate = MCPResolvedJailbreakPath(@"/");
        rootPath = candidate.length > 0 ? candidate : @"/var/jb";
    } else if ([packageScheme isEqualToString:@"rootless"] || MCPDirectoryExists(@"/var/jb")) {
        if (![packageScheme isEqualToString:@"roothide"]) {
            type = @"rootless";
        }
        rootPath = @"/var/jb";
    }

    NSMutableDictionary *info = [@{
        @"type": type ?: @"unknown",
        @"packageScheme": packageScheme ?: @"unknown",
        @"packageArchitecture": packageArchitecture ?: @"unknown",
        @"rootPath": rootPath ?: @""
    } mutableCopy];

    if (debug) {
        info[@"helpers"] = @{
            @"mcpRoot": MCPHelperExecutableStatus(@"/usr/bin/mcp-root")
        };
    }

    return [info copy];
}

static BOOL MCPStateBool(NSDictionary *state, NSString *key, BOOL *outValue) {
    id value = [state isKindOfClass:[NSDictionary class]] ? state[key] : nil;
    if (!value || value == [NSNull null] || ![value respondsToSelector:@selector(boolValue)]) {
        return NO;
    }
    if (outValue) *outValue = [value boolValue];
    return YES;
}

static double MCPRandomUnit(void) {
    return ((double)arc4random_uniform(1000000) / 1000000.0);
}

static double MCPRoundedScreenPoint(double value) {
    return round(value * 10.0) / 10.0;
}

static NSDictionary *MCPRandomizedTapPointForElement(NSDictionary *element) {
    if (![element isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    NSDictionary *rect = [element[@"visible_rect"] isKindOfClass:[NSDictionary class]] ? element[@"visible_rect"] : nil;
    if (!rect) {
        rect = [element[@"rect"] isKindOfClass:[NSDictionary class]] ? element[@"rect"] : nil;
    }

    double x = 0.0;
    double y = 0.0;
    double width = 0.0;
    double height = 0.0;

    if (!MCPRectValuesFromDictionary(rect, &x, &y, &width, &height)) {
        NSDictionary *tap = [element[@"tap"] isKindOfClass:[NSDictionary class]] ? element[@"tap"] : nil;
        return tap;
    }

    // 控制随机点击范围：只在 rect 中间区域随机
    // 0.5 表示中间 50% 区域
    // 例如 rect: x=0 y=0 width=80 height=40
    // 最终随机区域: x=20 y=10 width=40 height=20
    double centerRatio = 0.5;

    double tapWidth = width * centerRatio;
    double tapHeight = height * centerRatio;

    double minX = x + (width - tapWidth) / 2.0;
    double maxX = minX + tapWidth;

    double minY = y + (height - tapHeight) / 2.0;
    double maxY = minY + tapHeight;

    double tapX = minX + ((maxX - minX) * MCPRandomUnit());
    double tapY = minY + ((maxY - minY) * MCPRandomUnit());

    tapX = MIN(MAX(tapX, x), x + width);
    tapY = MIN(MAX(tapY, y), y + height);

    return @{
        @"x": @(MCPRoundedScreenPoint(tapX)),
        @"y": @(MCPRoundedScreenPoint(tapY))
    };
}


@interface MCPServer ()
+ (instancetype)sharedInstance;
- (instancetype)init;
- (void)startOnPort:(uint16_t)port;
- (void)stop;
- (void)handleClient:(int)clientSocket;
- (NSData *)readChunkedMCPBodyFromSocket:(int)clientSocket
                             initialBody:(const char *)initialBody
                       initialBodyLength:(ssize_t)initialBodyLength
                             errorStatus:(int *)errorStatus
                            errorMessage:(NSString **)errorMessage;
- (void)handleMCPRequest:(NSData *)bodyData clientSocket:(int)clientSocket;
- (NSDictionary *)routeMCPRequest:(NSDictionary *)request;
- (NSDictionary *)handleInitialize:(id)reqId;
- (NSDictionary *)handleToolsList:(id)reqId;
- (NSDictionary *)handleToolsCall:(id)reqId params:(NSDictionary *)params;
- (NSDictionary *)executeListFiles:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeReadFile:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeSearchFiles:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeGetDeviceInfo:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeRunCommand:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeFetchURL:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeReadProjectSkill:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)mcpSuccess:(id)reqId text:(NSString *)text;
- (NSDictionary *)mcpSuccess:(id)reqId text:(NSString *)text isError:(BOOL)isError;
- (NSDictionary *)mcpError:(id)reqId code:(NSInteger)code message:(NSString *)message;
- (void)sendJSONResponse:(int)socket status:(int)status body:(NSDictionary *)body;
- (void)sendErrorResponse:(int)socket status:(int)status message:(NSString *)message;
- (void)sendMethodNotAllowedResponse:(int)socket allowedMethods:(NSString *)allowedMethods message:(NSString *)message;
- (void)sendEmptyResponse:(int)socket status:(int)status;
- (void)writeAll:(int)socket data:(NSData *)data;
@end

@implementation MCPServer {
    int _serverSocket;
    dispatch_source_t _acceptSource;
    dispatch_queue_t _clientQueue;
    NSString *_sessionId;
}

+ (instancetype)sharedInstance {
    static MCPServer *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[MCPServer alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _serverSocket = -1;
        _clientQueue = dispatch_queue_create("com.susu.mcp.client", DISPATCH_QUEUE_CONCURRENT);
        _sessionId = [[NSUUID UUID] UUIDString];
    }
    return self;
}

#pragma mark - Server Lifecycle

- (void)startOnPort:(uint16_t)port {
    if (_running) return;

    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) {
        MCP_LOG(@"Failed to create socket: %s", strerror(errno));
        return;
    }

    int reuse = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family      = AF_INET;
    addr.sin_port        = htons(port);
    addr.sin_addr.s_addr = INADDR_ANY;

    if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        MCP_LOG(@"Failed to bind on port %d: %s", port, strerror(errno));
        close(sock);
        return;
    }

    if (listen(sock, 8) < 0) {
        MCP_LOG(@"Failed to listen: %s", strerror(errno));
        close(sock);
        return;
    }

    _serverSocket = sock;
    _port = port;
    _running = YES;

    dispatch_queue_t queue = dispatch_queue_create("com.susu.mcp.accept", DISPATCH_QUEUE_CONCURRENT);
    _acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, sock, 0, queue);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_acceptSource, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        int client = accept(sock, NULL, NULL);
        if (client >= 0) {
            dispatch_async(self->_clientQueue, ^{
                [self handleClient:client];
            });
        }
    });

    dispatch_source_set_cancel_handler(_acceptSource, ^{
        close(sock);
    });

    dispatch_resume(_acceptSource);
    MCP_LOG(@"MCP server started on port %d", port);
}

- (void)stop {
    if (!_running) return;
    _running = NO;
    if (_acceptSource) {
        dispatch_source_cancel(_acceptSource);
        _acceptSource = nil;
    }
    _serverSocket = -1;
    MCP_LOG(@"MCP server stopped");
}

#pragma mark - HTTP Handling

- (void)handleClient:(int)clientSocket {
    // Set read timeout
    struct timeval tv = { .tv_sec = 10, .tv_usec = 0 };
    setsockopt(clientSocket, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    char *buffer = malloc(HTTP_BUF_SIZE);
    if (!buffer) { close(clientSocket); return; }

    ssize_t totalRead = 0;
    ssize_t headerEnd = -1;

    // Read until we have all headers (\r\n\r\n)
    while (totalRead < HTTP_BUF_SIZE - 1) {
        ssize_t n = read(clientSocket, buffer + totalRead, HTTP_BUF_SIZE - 1 - totalRead);
        if (n <= 0) break;
        totalRead += n;
        buffer[totalRead] = '\0';

        // Check for header termination
        char *sep = strstr(buffer, "\r\n\r\n");
        if (sep) {
            headerEnd = sep - buffer + 4;
            break;
        }
    }

    if (headerEnd < 0) {
        [self sendErrorResponse:clientSocket status:400 message:@"Bad Request"];
        free(buffer);
        close(clientSocket);
        return;
    }

    // Parse request line and headers
    NSString *headerStr = [[NSString alloc] initWithBytes:buffer length:headerEnd encoding:NSUTF8StringEncoding];
    NSString *method = nil;
    NSString *path = nil;
    NSInteger contentLength = -1;
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];

    NSArray *lines = [headerStr componentsSeparatedByString:@"\r\n"];
    if (lines.count > 0) {
        NSArray *parts = [lines[0] componentsSeparatedByString:@" "];
        if (parts.count >= 2) {
            method = parts[0];
            path = parts[1];
        }
    }

    for (NSString *line in lines) {
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        NSString *name = [[line substringToIndex:colon.location] lowercaseString];
        NSString *value = [[line substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (name.length > 0) {
            headers[name] = value ?: @"";
        }
    }
    NSString *contentLengthHeader = headers[@"content-length"];
    if (contentLengthHeader.length > 0) {
        contentLength = contentLengthHeader.integerValue;
    }
    NSString *transferEncoding = [headers[@"transfer-encoding"] lowercaseString] ?: @"";
    BOOL chunkedBody = [transferEncoding containsString:@"chunked"];

    ssize_t bodyReceived = totalRead - headerEnd;
    NSString *basePath = MCPBasePath(path);

    // Route request
    if ([method isEqualToString:@"POST"] && [basePath isEqualToString:@"/mcp"]) {
        NSString *expect = [headers[@"expect"] lowercaseString] ?: @"";
        if ([expect containsString:@"100-continue"]) {
            NSData *continueData = [@"HTTP/1.1 100 Continue\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
            [self writeAll:clientSocket data:continueData];
        }

        if (chunkedBody) {
            int errorStatus = 400;
            NSString *errorMessage = nil;
            NSData *bodyData = [self readChunkedMCPBodyFromSocket:clientSocket
                                                      initialBody:buffer + headerEnd
                                                initialBodyLength:MAX((ssize_t)0, bodyReceived)
                                                      errorStatus:&errorStatus
                                                     errorMessage:&errorMessage];
            if (!bodyData) {
                [self sendErrorResponse:clientSocket status:errorStatus message:errorMessage ?: @"Invalid chunked MCP request body"];
                free(buffer);
                close(clientSocket);
                return;
            }

            [self handleMCPRequest:bodyData clientSocket:clientSocket];
            free(buffer);
            close(clientSocket);
            return;
        }

        if (contentLength < 0) contentLength = 0;
        if (contentLength > HTTP_BUF_SIZE - headerEnd - 1) {
            [self sendErrorResponse:clientSocket status:413 message:@"MCP request body too large"];
            free(buffer);
            close(clientSocket);
            return;
        }

        while (bodyReceived < contentLength && totalRead < HTTP_BUF_SIZE - 1) {
            ssize_t n = read(clientSocket, buffer + totalRead, MIN(HTTP_BUF_SIZE - 1 - totalRead, contentLength - bodyReceived));
            if (n <= 0) break;
            totalRead += n;
            bodyReceived += n;
        }
        buffer[totalRead] = '\0';

        if (bodyReceived < contentLength) {
            [self sendErrorResponse:clientSocket status:400 message:@"Incomplete MCP request body"];
            free(buffer);
            close(clientSocket);
            return;
        }

        NSData *bodyData = [NSData dataWithBytes:buffer + headerEnd length:MIN(bodyReceived, contentLength)];
        [self handleMCPRequest:bodyData clientSocket:clientSocket];
    } else if ([basePath isEqualToString:@"/mcp"]) {
        [self sendMethodNotAllowedResponse:clientSocket allowedMethods:@"POST" message:@"Method Not Allowed"];
    } else if ([method isEqualToString:@"GET"] && [basePath isEqualToString:@"/health"]) {
        NSDictionary *health = @{@"status": @"ok", @"server": MCP_SERVER_NAME, @"version": MCP_SERVER_VERSION};
        [self sendJSONResponse:clientSocket status:200 body:health];
    } else {
        [self sendErrorResponse:clientSocket status:404 message:@"Not Found"];
    }

    free(buffer);
    close(clientSocket);
}

- (NSData *)readChunkedMCPBodyFromSocket:(int)clientSocket
                             initialBody:(const char *)initialBody
                       initialBodyLength:(ssize_t)initialBodyLength
                             errorStatus:(int *)errorStatus
                            errorMessage:(NSString **)errorMessage {
    NSMutableData *encoded = [NSMutableData data];
    if (initialBody && initialBodyLength > 0) {
        [encoded appendBytes:initialBody length:(NSUInteger)initialBodyLength];
    }

    NSMutableData *decoded = [NSMutableData data];
    NSUInteger offset = 0;

    BOOL (^readMore)(void) = ^BOOL {
        uint8_t chunk[64 * 1024];
        while (YES) {
            ssize_t n = read(clientSocket, chunk, sizeof(chunk));
            if (n < 0 && errno == EINTR) {
                continue;
            }
            if (n <= 0) {
                return NO;
            }
            [encoded appendBytes:chunk length:(NSUInteger)n];
            return YES;
        }
    };

    while (YES) {
        NSRange lineEnd = MCPFindCRLF(encoded, offset);
        while (lineEnd.location == NSNotFound) {
            if (encoded.length >= offset && encoded.length - offset > MCP_MAX_CHUNK_LINE) {
                MCPSetHTTPBodyError(errorStatus, errorMessage, 400, @"Malformed chunked MCP request body");
                return nil;
            }
            if (!readMore()) {
                MCPSetHTTPBodyError(errorStatus, errorMessage, 400, @"Incomplete chunked MCP request body");
                return nil;
            }
            lineEnd = MCPFindCRLF(encoded, offset);
        }

        NSData *lineData = [encoded subdataWithRange:NSMakeRange(offset, lineEnd.location - offset)];
        unsigned long long chunkSize = 0;
        if (!MCPParseHTTPChunkSize(lineData, &chunkSize)) {
            MCPSetHTTPBodyError(errorStatus, errorMessage, 400, @"Malformed chunked MCP request body");
            return nil;
        }

        offset = lineEnd.location + 2;
        if (chunkSize == 0) {
            return [decoded copy];
        }

        if (chunkSize > (unsigned long long)HTTP_BUF_SIZE ||
            decoded.length > HTTP_BUF_SIZE - (NSUInteger)chunkSize) {
            MCPSetHTTPBodyError(errorStatus, errorMessage, 413, @"MCP request body too large");
            return nil;
        }

        NSUInteger chunkLength = (NSUInteger)chunkSize;
        NSUInteger needed = chunkLength + 2;
        while (encoded.length < offset || encoded.length - offset < needed) {
            if (!readMore()) {
                MCPSetHTTPBodyError(errorStatus, errorMessage, 400, @"Incomplete chunked MCP request body");
                return nil;
            }
        }

        const uint8_t *bytes = encoded.bytes;
        if (bytes[offset + chunkLength] != '\r' || bytes[offset + chunkLength + 1] != '\n') {
            MCPSetHTTPBodyError(errorStatus, errorMessage, 400, @"Malformed chunked MCP request body");
            return nil;
        }

        [decoded appendBytes:bytes + offset length:chunkLength];
        offset += needed;

        if (offset > 64 * 1024) {
            [encoded replaceBytesInRange:NSMakeRange(0, offset) withBytes:NULL length:0];
            offset = 0;
        }
    }
}

- (void)handleMCPRequest:(NSData *)bodyData clientSocket:(int)clientSocket {
    @try {
        NSError *jsonError;
        id jsonObj = [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:&jsonError];
        if (jsonError || ![jsonObj isKindOfClass:[NSDictionary class]]) {
            NSDictionary *errResp = @{
                @"jsonrpc": @"2.0",
                @"id": [NSNull null],
                @"error": @{@"code": @(-32700), @"message": @"Parse error"}
            };
            [self sendJSONResponse:clientSocket status:200 body:errResp];
            return;
        }

        NSDictionary *request = (NSDictionary *)jsonObj;
        NSDictionary *response = [self routeMCPRequest:request];

        if (response) {
            [self sendJSONResponse:clientSocket status:200 body:response];
        } else {
            // Notification — no response needed, but send 202
            [self sendEmptyResponse:clientSocket status:202];
        }
    } @catch (NSException *exception) {
        MCP_LOG(@"Unhandled exception while processing MCP request: %@ - %@", exception.name, exception.reason);
        NSDictionary *errResp = @{
            @"jsonrpc": @"2.0",
            @"id": [NSNull null],
            @"error": @{
                @"code": @(-32000),
                @"message": [NSString stringWithFormat:@"Internal server exception: %@", exception.reason ?: exception.name ?: @"unknown"]
            }
        };
        [self sendJSONResponse:clientSocket status:200 body:errResp];
    }
}

#pragma mark - MCP Protocol Router

- (NSDictionary *)routeMCPRequest:(NSDictionary *)request {
    id methodValue = request[@"method"];
    NSString *method = [methodValue isKindOfClass:[NSString class]] ? methodValue : nil;
    id reqId = request[@"id"];
    id paramsValue = request[@"params"];
    NSDictionary *params = nil;

    if (!method) {
        return [self mcpError:reqId code:-32600 message:@"Invalid request: method must be a string"];
    }

    if (!paramsValue || paramsValue == [NSNull null]) {
        params = @{};
    } else if ([paramsValue isKindOfClass:[NSDictionary class]]) {
        params = paramsValue;
    } else {
        return [self mcpError:reqId code:-32602 message:@"Invalid params: expected object"];
    }

    if ([method isEqualToString:@"initialize"]) {
        return [self handleInitialize:reqId];
    } else if ([method isEqualToString:@"notifications/initialized"]) {
        return nil; // notification, no response
    } else if ([method isEqualToString:@"ping"]) {
        return @{@"jsonrpc": @"2.0", @"id": reqId ?: [NSNull null], @"result": @{}};
    } else if ([method isEqualToString:@"tools/list"]) {
        return [self handleToolsList:reqId];
    } else if ([method isEqualToString:@"tools/call"]) {
        return [self handleToolsCall:reqId params:params];
    } else {
        return @{
            @"jsonrpc": @"2.0",
            @"id": reqId ?: [NSNull null],
            @"error": @{@"code": @(-32601), @"message": [NSString stringWithFormat:@"Method not found: %@", method]}
        };
    }
}

#pragma mark - MCP: initialize

- (NSDictionary *)handleInitialize:(id)reqId {
    return @{
        @"jsonrpc": @"2.0",
        @"id": reqId ?: [NSNull null],
        @"result": @{
            @"protocolVersion": MCP_PROTOCOL_VERSION,
            @"capabilities": @{
                @"tools": @{@"listChanged": @NO}
            },
            @"serverInfo": @{
                @"name": MCP_SERVER_NAME,
                @"version": MCP_SERVER_VERSION
            },
            @"instructions": @"Use com.susu.mcp to inspect files on the connected iPhone and run shell commands.\n\nFiles: list_files lists directory contents, read_file reads text files, and search_files searches file contents.\n\nDevice info: get_device_info for model, iOS version, battery, storage, memory, and jailbreak type/package information.\n\nShell: run_command executes shell commands on the device (timeout default 10s, max 30s).\n\nWeb: fetch_url fetches HTTP/HTTPS URL content.\n\nProject skills: read_project_skill reads skill.md or SKILL.md from a project root before project work.\n\nHealth checks: avoid shell brace expansion such as for i in {1..30}; use seq or a while loop, and set request timeouts for /health."
        }
    };
}

#pragma mark - MCP: tools/list

- (NSDictionary *)handleToolsList:(id)reqId {
    NSArray *tools = @[
        @{
            @"name": @"list_files",
            @"description": @"List files and directories under a path",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"path": @{@"type": @"string", @"description": @"Directory path (default: current directory)"},
                    @"recursive": @{@"type": @"boolean", @"description": @"List recursively (default: false)"},
                    @"max_depth": @{@"type": @"integer", @"description": @"Maximum recursion depth (default: 2)"},
                    @"include_hidden": @{@"type": @"boolean", @"description": @"Include hidden files (default: false)"},
                    @"max_entries": @{@"type": @"integer", @"description": @"Maximum entries to return (default: 3000, max: 10000)"}
                }
            }
        },
        @{
            @"name": @"read_file",
            @"description": @"Read a UTF-8 text file, optionally by line range",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"path": @{@"type": @"string", @"description": @"File path to read"},
                    @"start_line": @{@"type": @"integer", @"description": @"1-based start line"},
                    @"end_line": @{@"type": @"integer", @"description": @"1-based end line"},
                    @"max_bytes": @{@"type": @"integer", @"description": @"Maximum bytes to return (default: 200000)"}
                },
                @"required": @[@"path"]
            }
        },
        @{
            @"name": @"search_files",
            @"description": @"Search text files under a path and return matching lines",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"path": @{@"type": @"string", @"description": @"Directory path to search"},
                    @"query": @{@"type": @"string", @"description": @"Text or regular expression to search for"},
                    @"regex": @{@"type": @"boolean", @"description": @"Treat query as regular expression (default: false)"},
                    @"case_sensitive": @{@"type": @"boolean", @"description": @"Case-sensitive search (default: true)"},
                    @"max_results": @{@"type": @"integer", @"description": @"Maximum matches to return (default: 200)"}
                },
                @"required": @[@"path", @"query"]
            }
        },
        @{
            @"name": @"get_device_info",
            @"description": @"Get device information including model, iOS version, battery level, storage, memory, and jailbreak type/package information",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"debug": @{@"type": @"boolean", @"description": @"Include diagnostic helper executable status (default: false)"}
                }
            }
        },
        @{
            @"name": @"run_command",
            @"description": @"Execute a shell command on the device and return stdout/stderr output. Use for file operations, process management, system queries, etc.",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"command": @{@"type": @"string", @"description": @"Shell command to execute (e.g. ls -la, uname -a, cat /etc/hosts)"},
                    @"timeout": @{@"type": @"number", @"description": @"Timeout in seconds (default: 10, max: 30)"}
                },
                @"required": @[@"command"]
            }
        },
        @{
            @"name": @"fetch_url",
            @"description": @"Fetch HTTP/HTTPS URL content and return status code, headers, body text, and optional parsed content",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"url": @{@"type": @"string", @"description": @"HTTP or HTTPS URL to fetch"},
                    @"timeout": @{@"type": @"number", @"description": @"Timeout in seconds (default: 15, max: 30)"},
                    @"max_bytes": @{@"type": @"integer", @"description": @"Maximum response bytes to return (default: 200000, max: 1048576)"},
                    @"parse": @{@"type": @"string", @"description": @"Response parsing mode: auto, text, json, html, or none (default: auto)"}
                },
                @"required": @[@"url"]
            }
        },
        @{
            @"name": @"read_project_skill",
            @"description": @"Read project-level skill instructions from skill.md or SKILL.md in a project root directory",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"path": @{@"type": @"string", @"description": @"Absolute path to the project root directory"},
                    @"max_bytes": @{@"type": @"integer", @"description": @"Maximum bytes to read (default: 200000, max: 1048576)"}
                },
                @"required": @[@"path"]
            }
        }
    ];

    return @{
        @"jsonrpc": @"2.0",
        @"id": reqId ?: [NSNull null],
        @"result": @{@"tools": tools}
    };
}

#pragma mark - MCP: tools/call

- (NSDictionary *)handleToolsCall:(id)reqId params:(NSDictionary *)params {
    if (![params isKindOfClass:[NSDictionary class]]) {
        return [self mcpError:reqId code:-32602 message:@"Invalid params: expected object"];
    }

    id toolNameValue = params[@"name"];
    NSString *toolName = [toolNameValue isKindOfClass:[NSString class]] ? toolNameValue : nil;

    id argsValue = params[@"arguments"];
    NSDictionary *args = nil;
    if (!argsValue || argsValue == [NSNull null]) {
        args = @{};
    } else if ([argsValue isKindOfClass:[NSDictionary class]]) {
        args = argsValue;
    } else {
        return [self mcpError:reqId code:-32602 message:@"Invalid arguments: expected object"];
    }

    if (!toolName) {
        return [self mcpError:reqId code:-32602 message:@"Missing tool name"];
    }

    if ([toolName isEqualToString:@"list_files"]) {
        return [self executeListFiles:reqId args:args];
    } else if ([toolName isEqualToString:@"read_file"]) {
        return [self executeReadFile:reqId args:args];
    } else if ([toolName isEqualToString:@"search_files"]) {
        return [self executeSearchFiles:reqId args:args];
    } else if ([toolName isEqualToString:@"get_device_info"]) {
        return [self executeGetDeviceInfo:reqId args:args];
    } else if ([toolName isEqualToString:@"run_command"]) {
        return [self executeRunCommand:reqId args:args];
    } else if ([toolName isEqualToString:@"fetch_url"]) {
        return [self executeFetchURL:reqId args:args];
    } else if ([toolName isEqualToString:@"read_project_skill"]) {
        return [self executeReadProjectSkill:reqId args:args];
    }
    return [self mcpError:reqId code:-32602 message:[NSString stringWithFormat:@"Unknown tool: %@", toolName]];
}

#pragma mark - Tool Execution Helpers


#pragma mark - File Tools Execution

- (NSDictionary *)executeListFiles:(id)reqId args:(NSDictionary *)args {
    NSString *path = nil;
    NSString *paramError = nil;
    if (!MCPStringFromArgs(args, @"path", NO, &path, &paramError)) return [self mcpError:reqId code:-32602 message:paramError];
    BOOL recursive = NO;
    if (!MCPBoolFromArgs(args, @"recursive", NO, &recursive, &paramError)) return [self mcpError:reqId code:-32602 message:paramError];
    BOOL includeHidden = NO;
    if (!MCPBoolFromArgs(args, @"include_hidden", NO, &includeHidden, &paramError)) return [self mcpError:reqId code:-32602 message:paramError];
    NSInteger maxDepth = MCPIntegerFromArgs(args, @"max_depth", 2);
    if (maxDepth < 0) maxDepth = 0;
    if (maxDepth > 8) maxDepth = 8;
    NSInteger maxEntries = MCPIntegerFromArgs(args, @"max_entries", 3000);
    if (maxEntries <= 0) maxEntries = 3000;
    if (maxEntries > 10000) maxEntries = 10000;

    NSString *root = MCPResolvedToolPath(path ?: @".");
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:root isDirectory:&isDir]) {
        return [self mcpSuccess:reqId text:MCPJSONString(@{@"error": @"path_not_found", @"path": root}) isError:YES];
    }
    if (!isDir) {
        return [self mcpSuccess:reqId text:MCPJSONString(@{@"error": @"not_directory", @"path": root}) isError:YES];
    }

    NSMutableArray *entries = [NSMutableArray array];
    __block BOOL truncated = NO;
    void (^addEntry)(NSString *, NSInteger) = ^(NSString *entryPath, NSInteger depth) {
        if (entries.count >= (NSUInteger)maxEntries) { truncated = YES; return; }
        BOOL entryIsDir = NO;
        [fm fileExistsAtPath:entryPath isDirectory:&entryIsDir];
        NSDictionary *attrs = [fm attributesOfItemAtPath:entryPath error:nil] ?: @{};
        [entries addObject:@{
            @"path": MCPRelativePath(entryPath, root),
            @"type": MCPFileTypeFromAttributes(attrs, entryIsDir),
            @"size": attrs[NSFileSize] ?: @0,
            @"depth": @(depth)
        }];
    };

    if (recursive) {
        NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:root];
        NSMutableArray *relativePaths = [NSMutableArray array];
        for (NSString *relative in enumerator) {
            if (!includeHidden && [relative.lastPathComponent hasPrefix:@"."]) {
                [enumerator skipDescendants];
                continue;
            }
            NSInteger depth = [[relative pathComponents] count] - 1;
            if (depth > maxDepth) {
                [enumerator skipDescendants];
                continue;
            }
            [relativePaths addObject:relative];
            if (relativePaths.count > (NSUInteger)maxEntries) truncated = YES;
        }
        [relativePaths sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
        for (NSString *relative in relativePaths) {
            addEntry([root stringByAppendingPathComponent:relative], [[relative pathComponents] count] - 1);
            if (entries.count >= (NSUInteger)maxEntries) { truncated = YES; break; }
        }
    } else {
        NSArray *children = [fm contentsOfDirectoryAtPath:root error:nil];
        if (!children) {
            return [self mcpSuccess:reqId text:MCPJSONString(@{@"error": @"permission_denied_or_unreadable", @"path": root}) isError:YES];
        }
        NSMutableArray *dirs = [NSMutableArray array];
        NSMutableArray *files = [NSMutableArray array];
        for (NSString *name in children) {
            if (!includeHidden && [name hasPrefix:@"."]) continue;
            BOOL childIsDir = NO;
            NSString *child = [root stringByAppendingPathComponent:name];
            [fm fileExistsAtPath:child isDirectory:&childIsDir];
            [(childIsDir ? dirs : files) addObject:name];
        }
        [dirs sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
        [files sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
        for (NSString *name in [dirs arrayByAddingObjectsFromArray:files]) addEntry([root stringByAppendingPathComponent:name], 0);
    }

    return [self mcpSuccess:reqId text:MCPJSONString(@{@"path": root, @"entries": entries, @"truncated": @(truncated), @"max_entries": @(maxEntries)})];
}


- (NSDictionary *)executeReadFile:(id)reqId args:(NSDictionary *)args {
    NSString *path = nil;
    NSString *paramError = nil;
    if (!MCPStringFromArgs(args, @"path", YES, &path, &paramError)) return [self mcpError:reqId code:-32602 message:paramError];
    NSString *resolved = MCPResolvedToolPath(path);
    NSInteger maxBytes = MCPIntegerFromArgs(args, @"max_bytes", 200000);
    if (maxBytes <= 0) maxBytes = 200000;
    if (maxBytes > 1024 * 1024) maxBytes = 1024 * 1024;

    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:resolved isDirectory:&isDir]) {
        return [self mcpSuccess:reqId text:MCPJSONString(@{@"error": @"path_not_found", @"path": resolved}) isError:YES];
    }
    if (isDir) {
        return [self mcpSuccess:reqId text:MCPJSONString(@{@"error": @"is_directory", @"path": resolved}) isError:YES];
    }

    NSData *data = [NSData dataWithContentsOfFile:resolved];
    if (!data) return [self mcpSuccess:reqId text:MCPJSONString(@{@"error": @"read_failed", @"path": resolved}) isError:YES];
    if (MCPDataLooksBinary(data)) {
        return [self mcpSuccess:reqId text:MCPJSONString(@{@"error": @"not_utf8_text", @"path": resolved}) isError:YES];
    }

    BOOL truncated = NO;
    if (data.length > (NSUInteger)maxBytes) {
        data = [data subdataWithRange:NSMakeRange(0, (NSUInteger)maxBytes)];
        truncated = YES;
    }
    NSString *content = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!content) {
        return [self mcpSuccess:reqId text:MCPJSONString(@{@"error": @"decode_failed", @"encoding": @"utf-8", @"path": resolved}) isError:YES];
    }

    NSInteger startLine = MCPIntegerFromArgs(args, @"start_line", 0);
    NSInteger endLine = MCPIntegerFromArgs(args, @"end_line", 0);
    NSInteger actualStart = 1;
    NSInteger actualEnd = 0;
    NSString *warning = nil;
    NSArray *lines = [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSInteger totalLines = content.length ? (NSInteger)lines.count : 0;

    if (startLine > 0 || endLine > 0) {
        actualStart = startLine > 0 ? startLine : 1;
        actualEnd = endLine > 0 ? endLine : totalLines;
        if (actualStart > totalLines || actualStart > actualEnd) {
            content = @"";
            warning = @"range_out_of_file";
        } else {
            if (actualEnd > totalLines) { actualEnd = totalLines; warning = @"range_clamped"; }
            content = [[lines subarrayWithRange:NSMakeRange((NSUInteger)actualStart - 1, (NSUInteger)(actualEnd - actualStart + 1))] componentsJoinedByString:@"\n"];
        }
    } else {
        actualEnd = totalLines;
    }

    NSMutableDictionary *result = [@{
        @"path": resolved,
        @"content": content ?: @"",
        @"truncated": @(truncated),
        @"max_bytes": @(maxBytes),
        @"total_lines": @(totalLines),
        @"start_line": @(actualStart),
        @"end_line": @(actualEnd)
    } mutableCopy];
    if (warning) result[@"warning"] = warning;
    return [self mcpSuccess:reqId text:MCPJSONString(result)];
}


- (NSDictionary *)executeSearchFiles:(id)reqId args:(NSDictionary *)args {
    NSString *path = nil;
    NSString *query = nil;
    NSString *paramError = nil;
    if (!MCPStringFromArgs(args, @"path", YES, &path, &paramError)) return [self mcpError:reqId code:-32602 message:paramError];
    if (!MCPStringFromArgs(args, @"query", YES, &query, &paramError)) return [self mcpError:reqId code:-32602 message:paramError];
    BOOL regex = NO;
    if (!MCPBoolFromArgs(args, @"regex", NO, &regex, &paramError)) return [self mcpError:reqId code:-32602 message:paramError];
    BOOL caseSensitive = YES;
    if (!MCPBoolFromArgs(args, @"case_sensitive", YES, &caseSensitive, &paramError)) return [self mcpError:reqId code:-32602 message:paramError];
    NSInteger maxResults = MCPIntegerFromArgs(args, @"max_results", 200);
    if (maxResults <= 0) maxResults = 200;
    if (maxResults > 2000) maxResults = 2000;

    NSString *root = MCPResolvedToolPath(path);
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:root isDirectory:&isDir]) {
        return [self mcpSuccess:reqId text:MCPJSONString(@{@"error": @"path_not_found", @"path": root}) isError:YES];
    }
    if (!isDir) {
        return [self mcpSuccess:reqId text:MCPJSONString(@{@"error": @"not_directory", @"path": root}) isError:YES];
    }

    NSRegularExpression *expression = nil;
    if (regex) {
        NSError *regexError = nil;
        expression = [NSRegularExpression regularExpressionWithPattern:query options:(caseSensitive ? 0 : NSRegularExpressionCaseInsensitive) error:&regexError];
        if (!expression) {
            return [self mcpError:reqId code:-32602 message:[NSString stringWithFormat:@"Invalid regular expression: %@", regexError.localizedDescription ?: @""]];
        }
    }

    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:root];
    NSMutableArray *matches = [NSMutableArray array];
    BOOL truncated = NO;
    for (NSString *relative in enumerator) {
        if (matches.count >= (NSUInteger)maxResults) { truncated = YES; break; }
        NSString *name = relative.lastPathComponent;
        if ([name hasPrefix:@"."]) { [enumerator skipDescendants]; continue; }
        if (MCPSearchShouldSkipDirectory(name)) { [enumerator skipDescendants]; continue; }
        NSString *filePath = [root stringByAppendingPathComponent:relative];
        BOOL entryIsDir = NO;
        [fm fileExistsAtPath:filePath isDirectory:&entryIsDir];
        if (entryIsDir) continue;
        if (MCPSearchShouldSkipExtension(filePath)) continue;
        NSDictionary *attrs = [fm attributesOfItemAtPath:filePath error:nil] ?: @{};
        if (![MCPFileTypeFromAttributes(attrs, entryIsDir) isEqualToString:@"file"]) continue;
        NSData *data = [NSData dataWithContentsOfFile:filePath options:0 error:nil];
        if (!data || data.length > 1024 * 1024 || MCPDataLooksBinary(data)) continue;
        NSString *content = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!content) continue;
        NSArray *lines = [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
        for (NSUInteger i = 0; i < lines.count && matches.count < (NSUInteger)maxResults; i++) {
            NSString *line = lines[i];
            BOOL found = NO;
            if (regex) {
                found = [expression firstMatchInString:line options:0 range:NSMakeRange(0, line.length)] != nil;
            } else if (caseSensitive) {
                found = [line containsString:query];
            } else {
                found = [line rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound;
            }
            if (found) {
                [matches addObject:@{@"path": relative, @"line": @(i + 1), @"text": line}];
            }
        }
    }

    return [self mcpSuccess:reqId text:MCPJSONString(@{
        @"path": root,
        @"query": query,
        @"matches": matches,
        @"truncated": @(truncated || matches.count >= (NSUInteger)maxResults),
        @"max_results": @(maxResults),
        @"regex": @(regex),
        @"case_sensitive": @(caseSensitive)
    })];
}


#pragma mark - Device Info Execution

- (NSDictionary *)executeGetDeviceInfo:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    BOOL debug = NO;
    if (!MCPBoolFromArgs(args, @"debug", NO, &debug, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }

    __block NSDictionary *info = nil;

    dispatch_block_t block = ^{
        NSMutableDictionary *result = [NSMutableDictionary dictionary];

        // Device model and name
        struct utsname systemInfo;
        uname(&systemInfo);
        result[@"machine"] = [NSString stringWithCString:systemInfo.machine encoding:NSUTF8StringEncoding] ?: @"unknown";
        result[@"deviceName"] = [[UIDevice currentDevice] name] ?: @"unknown";
        result[@"systemName"] = [[UIDevice currentDevice] systemName] ?: @"unknown";
        result[@"systemVersion"] = [[UIDevice currentDevice] systemVersion] ?: @"unknown";
        result[@"model"] = [[UIDevice currentDevice] model] ?: @"unknown";
        result[@"jailbreak"] = MCPJailbreakInfo(debug);

        // Battery
        [[UIDevice currentDevice] setBatteryMonitoringEnabled:YES];
        float batteryLevel = [[UIDevice currentDevice] batteryLevel];
        UIDeviceBatteryState batteryState = [[UIDevice currentDevice] batteryState];
        result[@"batteryLevel"] = batteryLevel >= 0 ? @(batteryLevel * 100) : @(-1);
        NSString *stateStr = @"unknown";
        switch (batteryState) {
            case UIDeviceBatteryStateUnplugged: stateStr = @"unplugged"; break;
            case UIDeviceBatteryStateCharging:  stateStr = @"charging"; break;
            case UIDeviceBatteryStateFull:      stateStr = @"full"; break;
            default: break;
        }
        result[@"batteryState"] = stateStr;

        // Storage
        struct statvfs stat;
        if (statvfs("/var", &stat) == 0) {
            unsigned long long freeBytes = (unsigned long long)stat.f_bavail * stat.f_frsize;
            unsigned long long totalBytes = (unsigned long long)stat.f_blocks * stat.f_frsize;
            result[@"storageFreeBytes"] = @(freeBytes);
            result[@"storageTotalBytes"] = @(totalBytes);
            result[@"storageFreeGB"] = @(freeBytes / (1024.0 * 1024.0 * 1024.0));
            result[@"storageTotalGB"] = @(totalBytes / (1024.0 * 1024.0 * 1024.0));
        }

        // Memory
        mach_port_t host = mach_host_self();
        vm_size_t pageSize;
        host_page_size(host, &pageSize);
        vm_statistics64_data_t vmStat;
        mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
        if (host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vmStat, &count) == KERN_SUCCESS) {
            unsigned long long freeMemory = (unsigned long long)vmStat.free_count * pageSize;
            unsigned long long totalMemory = [NSProcessInfo processInfo].physicalMemory;
            result[@"memoryFreeBytes"] = @(freeMemory);
            result[@"memoryTotalBytes"] = @(totalMemory);
            result[@"memoryFreeMB"] = @(freeMemory / (1024.0 * 1024.0));
            result[@"memoryTotalMB"] = @(totalMemory / (1024.0 * 1024.0));
        }

        // Screen
        UIScreen *screen = [UIScreen mainScreen];
        result[@"screenWidth"] = @(screen.bounds.size.width);
        result[@"screenHeight"] = @(screen.bounds.size.height);
        result[@"screenScale"] = @(screen.scale);

        // Uptime
        result[@"uptimeSeconds"] = @([NSProcessInfo processInfo].systemUptime);

        info = [result copy];
    };

    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }

    if (info) {
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:info options:0 error:nil];
        NSString *jsonStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        return [self mcpSuccess:reqId text:jsonStr];
    }
    return [self mcpSuccess:reqId text:@"Failed to get device info" isError:YES];
}

#pragma mark - Shell Command Execution

- (NSDictionary *)executeRunCommand:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    NSString *command = nil;
    if (!MCPStringFromArgs(args, @"command", YES, &command, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }

    double timeoutSec = 10;
    if (!MCPNumberFromArgs(args, @"timeout", 10, NO, &timeoutSec, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }
    if (timeoutSec <= 0) timeoutSec = 10;
    if (timeoutSec > 30) timeoutSec = 30;

    NSString *shellPath = MCPResolvedJailbreakPath(@"/bin/sh");
    NSString *output = nil;
    NSString *runError = nil;
    int exitCode = -1;
    BOOL finished = MCPRunProcess(shellPath,
                                  @[@"-lc", command],
                                  MCPJailbreakEnvironment(),
                                  timeoutSec,
                                  512 * 1024,
                                  &output,
                                  &exitCode,
                                  &runError);

    if (!finished && [runError hasPrefix:@"Command timed out"]) {
        return [self mcpSuccess:reqId text:runError isError:YES];
    }

    NSMutableDictionary *resultDict = [@{
        @"exitCode": @(exitCode),
        @"output": output ?: @""
    } mutableCopy];
    if (runError.length > 0) {
        resultDict[@"error"] = runError;
    }
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:resultDict options:0 error:nil];
    NSString *jsonStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];

    if (!finished || exitCode != 0) {
        return [self mcpSuccess:reqId text:jsonStr isError:YES];
    }
    return [self mcpSuccess:reqId text:jsonStr];
}


#pragma mark - URL Fetch Execution

static NSString *MCPTrimmedString(NSString *s) {
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
}

static NSString *MCPHTMLDecode(NSString *s) {
    if (!s) return @"";
    NSMutableString *m = [s mutableCopy];
    NSDictionary *entities = @{@"&nbsp;": @" ", @"&amp;": @"&", @"&lt;": @"<", @"&gt;": @">", @"&quot;": @"\"", @"&#39;": @"'", @"&apos;": @"'"};
    for (NSString *k in entities) [m replaceOccurrencesOfString:k withString:entities[k] options:NSCaseInsensitiveSearch range:NSMakeRange(0, m.length)];
    return m;
}

static NSString *MCPFirstRegexGroup(NSString *text, NSString *pattern) {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive|NSRegularExpressionDotMatchesLineSeparators error:nil];
    NSTextCheckingResult *match = [re firstMatchInString:text ?: @"" options:0 range:NSMakeRange(0, (text ?: @"").length)];
    if (!match || match.numberOfRanges < 2) return @"";
    return MCPHTMLDecode([[text substringWithRange:[match rangeAtIndex:1]] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]);
}

static NSDictionary *MCPParseHTML(NSString *body) {
    NSString *html = body ?: @"";
    NSMutableArray *headings = [NSMutableArray array];
    NSRegularExpression *hRe = [NSRegularExpression regularExpressionWithPattern:@"<h([1-3])[^>]*>(.*?)</h\\1>" options:NSRegularExpressionCaseInsensitive|NSRegularExpressionDotMatchesLineSeparators error:nil];
    for (NSTextCheckingResult *m in [hRe matchesInString:html options:0 range:NSMakeRange(0, html.length)]) {
        NSString *level = [html substringWithRange:[m rangeAtIndex:1]];
        NSString *text = [html substringWithRange:[m rangeAtIndex:2]];
        text = [text stringByReplacingOccurrencesOfString:@"<[^>]+>" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, text.length)];
        [headings addObject:@{@"level": @([level integerValue]), @"text": MCPHTMLDecode(MCPTrimmedString(text))}];
        if (headings.count >= 50) break;
    }

    NSMutableArray *links = [NSMutableArray array];
    NSRegularExpression *aRe = [NSRegularExpression regularExpressionWithPattern:@"<a[^>]+href=[\\\"']([^\\\"']+)[\\\"'][^>]*>(.*?)</a>" options:NSRegularExpressionCaseInsensitive|NSRegularExpressionDotMatchesLineSeparators error:nil];
    for (NSTextCheckingResult *m in [aRe matchesInString:html options:0 range:NSMakeRange(0, html.length)]) {
        NSString *href = [html substringWithRange:[m rangeAtIndex:1]];
        NSString *text = [html substringWithRange:[m rangeAtIndex:2]];
        text = [text stringByReplacingOccurrencesOfString:@"<[^>]+>" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, text.length)];
        [links addObject:@{@"text": MCPHTMLDecode(MCPTrimmedString(text)), @"href": MCPHTMLDecode(href)}];
        if (links.count >= 100) break;
    }

    NSString *plain = [html stringByReplacingOccurrencesOfString:@"<script[^>]*>.*?</script>" withString:@" " options:NSRegularExpressionSearch|NSCaseInsensitiveSearch range:NSMakeRange(0, html.length)];
    plain = [plain stringByReplacingOccurrencesOfString:@"<style[^>]*>.*?</style>" withString:@" " options:NSRegularExpressionSearch|NSCaseInsensitiveSearch range:NSMakeRange(0, plain.length)];
    plain = [plain stringByReplacingOccurrencesOfString:@"<[^>]+>" withString:@" " options:NSRegularExpressionSearch range:NSMakeRange(0, plain.length)];
    plain = [plain stringByReplacingOccurrencesOfString:@"\\s+" withString:@" " options:NSRegularExpressionSearch range:NSMakeRange(0, plain.length)];

    return @{@"title": MCPFirstRegexGroup(html, @"<title[^>]*>(.*?)</title>"),
             @"description": MCPFirstRegexGroup(html, @"<meta[^>]+name=[\\\"']description[\\\"'][^>]+content=[\\\"']([^\\\"']*)[\\\"'][^>]*>"),
             @"headings": headings,
             @"links": links,
             @"plainText": MCPHTMLDecode(MCPTrimmedString(plain))};
}

- (NSDictionary *)executeFetchURL:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    NSString *urlString = nil;
    if (!MCPStringFromArgs(args, @"url", YES, &urlString, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }

    NSString *parse = nil;
    if (!MCPStringFromArgs(args, @"parse", NO, &parse, &paramError)) return [self mcpError:reqId code:-32602 message:paramError];
    parse = (parse ?: @"auto").lowercaseString;
    NSSet *allowedParse = [NSSet setWithArray:@[@"auto", @"text", @"json", @"html", @"none"]];
    if (![allowedParse containsObject:parse]) return [self mcpError:reqId code:-32602 message:@"Invalid parse: expected auto, text, json, html, or none"];

    NSURL *url = [NSURL URLWithString:urlString];
    NSString *scheme = url.scheme.lowercaseString;
    if (!url || !([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) {
        return [self mcpError:reqId code:-32602 message:@"Invalid url: only http and https are supported"];
    }

    double timeoutSec = 15;
    if (!MCPNumberFromArgs(args, @"timeout", 15, NO, &timeoutSec, &paramError)) return [self mcpError:reqId code:-32602 message:paramError];
    if (timeoutSec <= 0) timeoutSec = 15;
    if (timeoutSec > 30) timeoutSec = 30;

    NSInteger maxBytes = MCPIntegerFromArgs(args, @"max_bytes", 200000);
    if (maxBytes <= 0) maxBytes = 200000;
    if (maxBytes > 1024 * 1024) maxBytes = 1024 * 1024;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    request.timeoutInterval = timeoutSec;
    [request setValue:@"com.susu.mcp/1.0" forHTTPHeaderField:@"User-Agent"];

    __block NSData *responseData = nil;
    __block NSURLResponse *urlResponse = nil;
    __block NSError *requestError = nil;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        responseData = data;
        urlResponse = response;
        requestError = error;
        dispatch_semaphore_signal(sema);
    }];
    [task resume];

    long waitResult = dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((timeoutSec + 1) * NSEC_PER_SEC)));
    if (waitResult != 0) {
        [task cancel];
        return [self mcpSuccess:reqId text:@"Request timed out" isError:YES];
    }
    if (requestError) return [self mcpSuccess:reqId text:requestError.localizedDescription ?: @"Request failed" isError:YES];

    NSHTTPURLResponse *httpResponse = [urlResponse isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)urlResponse : nil;
    BOOL truncated = NO;
    NSData *bodyData = responseData ?: [NSData data];
    if (bodyData.length > (NSUInteger)maxBytes) {
        bodyData = [bodyData subdataWithRange:NSMakeRange(0, (NSUInteger)maxBytes)];
        truncated = YES;
    }
    NSString *body = [[NSString alloc] initWithData:bodyData encoding:NSUTF8StringEncoding];
    if (!body) body = [[NSString alloc] initWithData:bodyData encoding:NSISOLatin1StringEncoding] ?: @"";

    NSString *contentType = @"";
    id ct = httpResponse.allHeaderFields[@"Content-Type"] ?: httpResponse.allHeaderFields[@"content-type"];
    if ([ct isKindOfClass:[NSString class]]) contentType = [(NSString *)ct lowercaseString];

    NSString *parseType = parse;
    if ([parse isEqualToString:@"auto"]) {
        NSString *trimmed = MCPTrimmedString(body);
        if ([contentType containsString:@"application/json"] || [contentType containsString:@"+json"] || (([trimmed hasPrefix:@"{"] && [trimmed hasSuffix:@"}"]) || ([trimmed hasPrefix:@"["] && [trimmed hasSuffix:@"]"]))) parseType = @"json";
        else if ([contentType containsString:@"text/html"] || [trimmed rangeOfString:@"<html" options:NSCaseInsensitiveSearch].location != NSNotFound || [trimmed rangeOfString:@"<!doctype html" options:NSCaseInsensitiveSearch].location != NSNotFound) parseType = @"html";
        else parseType = @"text";
    }

    id parsed = [NSNull null];
    id parseError = [NSNull null];
    if ([parseType isEqualToString:@"json"]) {
        NSError *jsonError = nil;
        id obj = [NSJSONSerialization JSONObjectWithData:[body dataUsingEncoding:NSUTF8StringEncoding] options:0 error:&jsonError];
        if (obj) parsed = obj;
        else parseError = [NSString stringWithFormat:@"JSON parse failed: %@%@", jsonError.localizedDescription ?: @"Invalid JSON", truncated ? @" (response may be truncated)" : @""];
    } else if ([parseType isEqualToString:@"html"]) {
        parsed = MCPParseHTML(body);
    }

    NSMutableDictionary *resultDict = [@{
        @"url": urlResponse.URL.absoluteString ?: urlString,
        @"statusCode": @(httpResponse ? httpResponse.statusCode : 0),
        @"headers": httpResponse.allHeaderFields ?: @{},
        @"contentType": contentType ?: @"",
        @"content": body ?: @"",
        @"parse": parse,
        @"parseType": parseType,
        @"parsed": parsed,
        @"parseError": parseError,
        @"truncated": @(truncated)
    } mutableCopy];
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:resultDict options:0 error:nil];
    NSString *jsonStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    return [self mcpSuccess:reqId text:jsonStr isError:(httpResponse && httpResponse.statusCode >= 400)];
}

#pragma mark - Project Skill Execution

- (NSDictionary *)executeReadProjectSkill:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    NSString *path = nil;
    if (!MCPStringFromArgs(args, @"path", YES, &path, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }

    NSInteger maxBytes = MCPIntegerFromArgs(args, @"max_bytes", 200000);
    if (maxBytes <= 0) maxBytes = 200000;
    if (maxBytes > 1024 * 1024) maxBytes = 1024 * 1024;

    NSString *root = MCPResolvedToolPath(path);
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:root isDirectory:&isDir] || !isDir) {
        return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"Project root is not a directory: %@", root] isError:YES];
    }

    NSString *skillPath = [root stringByAppendingPathComponent:@"skill.md"];
    if (![fm fileExistsAtPath:skillPath]) {
        skillPath = [root stringByAppendingPathComponent:@"SKILL.md"];
    }

    BOOL isSkillDir = NO;
    if (![fm fileExistsAtPath:skillPath isDirectory:&isSkillDir] || isSkillDir) {
        NSDictionary *resultDict = @{
            @"projectRoot": root,
            @"found": @NO,
            @"message": @"No skill.md or SKILL.md found in project root."
        };
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:resultDict options:0 error:nil];
        NSString *jsonStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        return [self mcpSuccess:reqId text:jsonStr];
    }

    NSData *data = [NSData dataWithContentsOfFile:skillPath];
    if (!data) {
        return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"Failed to read skill file: %@", skillPath] isError:YES];
    }

    BOOL truncated = NO;
    if (data.length > (NSUInteger)maxBytes) {
        data = [data subdataWithRange:NSMakeRange(0, (NSUInteger)maxBytes)];
        truncated = YES;
    }
    NSString *content = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!content) {
        return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"Skill file is not valid UTF-8 text: %@", skillPath] isError:YES];
    }

    NSDictionary *resultDict = @{
        @"projectRoot": root,
        @"skillPath": skillPath,
        @"found": @YES,
        @"content": content,
        @"truncated": @(truncated)
    };
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:resultDict options:0 error:nil];
    NSString *jsonStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    return [self mcpSuccess:reqId text:jsonStr];
}

#pragma mark - Response Builders

- (NSDictionary *)mcpSuccess:(id)reqId text:(NSString *)text {
    return [self mcpSuccess:reqId text:text isError:NO];
}

- (NSDictionary *)mcpSuccess:(id)reqId text:(NSString *)text isError:(BOOL)isError {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"content"] = @[@{@"type": @"text", @"text": text}];
    if (isError) result[@"isError"] = @YES;

    return @{
        @"jsonrpc": @"2.0",
        @"id": reqId ?: [NSNull null],
        @"result": result
    };
}

- (NSDictionary *)mcpError:(id)reqId code:(NSInteger)code message:(NSString *)message {
    return @{
        @"jsonrpc": @"2.0",
        @"id": reqId ?: [NSNull null],
        @"error": @{@"code": @(code), @"message": message}
    };
}

#pragma mark - HTTP Response Helpers

- (void)sendJSONResponse:(int)socket status:(int)status body:(NSDictionary *)body {
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    if (!jsonData) {
        [self sendErrorResponse:socket status:500 message:@"JSON serialization error"];
        return;
    }

    NSString *response = [NSString stringWithFormat:
        @"HTTP/1.1 %d OK\r\n"
        @"Content-Type: application/json\r\n"
        @"Content-Length: %lu\r\n"
        @"Mcp-Session-Id: %@\r\n"
        @"Connection: close\r\n"
        @"\r\n",
        status, (unsigned long)jsonData.length, _sessionId];

    NSMutableData *responseData = [NSMutableData dataWithData:[response dataUsingEncoding:NSUTF8StringEncoding]];
    [responseData appendData:jsonData];

    [self writeAll:socket data:responseData];
}

- (void)sendErrorResponse:(int)socket status:(int)status message:(NSString *)message {
    NSString *statusText;
    switch (status) {
        case 400: statusText = @"Bad Request"; break;
        case 411: statusText = @"Length Required"; break;
        case 413: statusText = @"Payload Too Large"; break;
        case 415: statusText = @"Unsupported Media Type"; break;
        case 404: statusText = @"Not Found"; break;
        case 405: statusText = @"Method Not Allowed"; break;
        case 500: statusText = @"Internal Server Error"; break;
        default:  statusText = @"Error"; break;
    }

    NSDictionary *body = @{@"error": message};
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSString *header = [NSString stringWithFormat:
        @"HTTP/1.1 %d %@\r\n"
        @"Content-Type: application/json\r\n"
        @"Content-Length: %lu\r\n"
        @"Connection: close\r\n"
        @"\r\n",
        status, statusText, (unsigned long)jsonData.length];

    NSMutableData *responseData = [NSMutableData dataWithData:[header dataUsingEncoding:NSUTF8StringEncoding]];
    [responseData appendData:jsonData];

    [self writeAll:socket data:responseData];
}

- (void)sendMethodNotAllowedResponse:(int)socket allowedMethods:(NSString *)allowedMethods message:(NSString *)message {
    NSDictionary *body = @{@"error": message ?: @"Method Not Allowed"};
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSString *header = [NSString stringWithFormat:
        @"HTTP/1.1 405 Method Not Allowed\r\n"
        @"Content-Type: application/json\r\n"
        @"Content-Length: %lu\r\n"
        @"Allow: %@\r\n"
        @"Connection: close\r\n"
        @"\r\n",
        (unsigned long)jsonData.length, allowedMethods ?: @"POST"];

    NSMutableData *responseData = [NSMutableData dataWithData:[header dataUsingEncoding:NSUTF8StringEncoding]];
    [responseData appendData:jsonData];

    [self writeAll:socket data:responseData];
}

- (void)sendEmptyResponse:(int)socket status:(int)status {
    NSString *response = [NSString stringWithFormat:
        @"HTTP/1.1 %d Accepted\r\n"
        @"Content-Length: 0\r\n"
        @"Mcp-Session-Id: %@\r\n"
        @"Connection: close\r\n"
        @"\r\n",
        status, _sessionId];

    NSData *data = [response dataUsingEncoding:NSUTF8StringEncoding];
    [self writeAll:socket data:data];
}

- (void)writeAll:(int)socket data:(NSData *)data {
    const uint8_t *bytes = data.bytes;
    NSUInteger remaining = data.length;
    NSUInteger offset = 0;

    while (remaining > 0) {
        ssize_t written = write(socket, bytes + offset, remaining);
        if (written <= 0) break;
        offset += written;
        remaining -= written;
    }
}

@end

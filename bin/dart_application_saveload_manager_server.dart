import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:mime/mime.dart';
import 'saveload_core_server.dart';

void main() async {
  late final HttpServer server;
  try {
    final port = int.parse(Platform.environment['PORT'] ?? '8000');
    server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    await infoPrint(server);
    final mdnsServers = await startMdnsServer(port);
    ProcessSignal.sigint.watch().listen((_) async {
      await stopAllServices(server, mdnsServers);
    });
    if (!Platform.isWindows) {
      ProcessSignal.sigterm.watch().listen((_) async {
        await stopAllServices(server, mdnsServers);
      });
    }
    print('✅ All services running! Press Ctrl+C to stop.');
  } catch (e) {
    print('❌ Server startup failed: $e');
    exit(1);
  }
  await for (HttpRequest request in server) {
    // addCorsHeaders(request.response);
    if (request.method == 'OPTIONS') {
      request.response
        ..statusCode = HttpStatus.noContent
        ..close();
      continue;
    }
    try {
      final path = request.uri.path;
      if (request.method == 'GET') {
        await handleGetRoutes(request, path);
      } else if (request.method == 'POST') {
        await handlePostRoutes(request, path);
      } else {
        request.response
          ..statusCode = HttpStatus.methodNotAllowed
          ..write('Unsupported method: ${request.method}')
          ..close();
      }
    } catch (e) {
      request.response
        ..statusCode = HttpStatus.internalServerError
        ..write('Server error: ${e.toString()}')
        ..close();
    }
  }
}

void addCorsHeaders(HttpResponse response) {
  response.headers
    ..add('Access-Control-Allow-Origin', '*')
    ..add('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS')
    ..add('Access-Control-Allow-Headers', 'Origin, Content-Type, Accept, Authorization')
    ..add('Access-Control-Allow-Credentials', 'true')
    ..add('Access-Control-Max-Age', '86400');
}

Future<void> handleGetRoutes(HttpRequest request, String path) async {
  try {
    switch (path) {
      case '/':
        await handleHome(request);
        break;
      default:
        await serveStaticFile(request, path.substring(1));
    }
  } catch (e) {
    print('GET route error: $e');
    request.response
      ..statusCode = HttpStatus.internalServerError
      ..write('Error processing request: ${e.toString()}')
      ..close();
  }
}

Future<void> handleHome(HttpRequest request) async {
  await serveStaticFile(request, 'index.html');
}

Future<void> serveStaticFile(HttpRequest request, String filename) async {
  try {
    if (filename.isEmpty) filename = 'index.html';
    if (filename.contains('..') || filename.contains('//')) {
      request.response
        ..statusCode = HttpStatus.forbidden
        ..write('Forbidden path')
        ..close();
      return;
    }
    final file = File('${Directory.current.path}/$staticFilesDir/$filename');
    print('Attempting to serve file: ${file.absolute.path}');
    if (await file.exists()) {
      final ext = filename.split('.').last.toLowerCase();
      final contentType = getContentType(ext);
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = contentType;
      // if (filename == 'flutter_bootstrap.js') {
      //   request.response.headers.set('Cache-Control', 'no-cache, no-store, must-revalidate');
      // }
      var bytes = await file.readAsBytes();
      request.response.add(bytes);
      await request.response.close();
    } else {
      print('File not found: ${file.absolute.path}');
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('File not found: $filename')
        ..close();
    }
  } catch (e) {
    print('Static file error: $e');
    request.response
      ..statusCode = HttpStatus.internalServerError
      ..write('Error serving file: ${e.toString()}')
      ..close();
  }
}

ContentType getContentType(String extension) {
  switch (extension) {
    case 'html':
      return ContentType.html;
    case 'css':
      return ContentType('text', 'css');
    case 'js':
      return ContentType('application', 'javascript');
    case 'png':
      return ContentType('image', 'png');
    case 'jpg':
    case 'jpeg':
      return ContentType('image', 'jpeg');
    case 'gif':
      return ContentType('image', 'gif');
    case 'json':
      return ContentType('application', 'json');
    default:
      return ContentType.binary;
  }
}

Future<void> handlePostRoutes(HttpRequest request, String path) async {
  switch (path) {
    case '/jsonrpc':
      await handleJsonrpc(request);
      break;
    case '/download':
      await handleDownload(request);
      break;
    case '/upload':
      await handleUpload(request);
      break;
    default:
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('Route not found: $path')
        ..close();
  }
}

Future<void> handleJsonrpc(HttpRequest request) async {
  try {
    final content = await utf8.decoder.bind(request).join();
    final jsonData = jsonDecode(content) as Map<String, dynamic>;
    if (jsonData['jsonrpc'] != '2.0') {
      sendErrorResponse(request.response, -32600, 'Invalid Request');
      return;
    }
    final method = jsonData['method'] as String?;
    final params = jsonData['params'] ?? [];
    final id = jsonData['id'];
    print('\nid: ${DateTime.fromMillisecondsSinceEpoch(id)}');
    print('method: $method');
    print('params: $params');
    if (method == null) {
      sendErrorResponse(request.response, -32600, 'Method is required');
      return;
    }
    final result = await executeMethod(method, params);
    print('result: $result');
    sendSuccessResponse(request.response, id, result);
  } catch (e) {
    sendErrorResponse(request.response, -32700, 'Parse error: $e');
  }
}

void sendSuccessResponse(HttpResponse response, id, result) {
  response
    ..statusCode = HttpStatus.ok
    ..headers.contentType = ContentType.json
    ..write(jsonEncode({'jsonrpc': '2.0', 'result': result, 'id': id}))
    ..close();
}

void sendErrorResponse(HttpResponse response, int code, String message, [id]) {
  response
    ..statusCode = HttpStatus.ok
    ..headers.contentType = ContentType.json
    ..write(
      jsonEncode({
        'jsonrpc': '2.0',
        'error': {'code': code, 'message': message},
        'id': id,
      }),
    )
    ..close();
}

Future<void> handleDownload(HttpRequest request) async {
  try {
    final content = await utf8.decoder.bind(request).join();
    final data = jsonDecode(content);
    final String game = data['game'];
    final String profile = data['profile'];
    final String save = data['save'];
    final Directory tempDir = Directory.systemTemp;
    final zipName = [game, profile, '$save.zip'].join('_');
    final String zipPath = [tempDir.path, zipName].join(Platform.pathSeparator);
    final savePath = ['SaveLoad', game, profile, save].join(Platform.pathSeparator);
    await compressToZip(savePath, zipPath);
    final File zipFile = File(zipPath);
    final List<int> bytes = await zipFile.readAsBytes();
    // Use RFC 5987 encoding
    final encodedName = Uri.encodeComponent(zipName);
    request.response
      ..headers.set(HttpHeaders.contentTypeHeader, 'application/zip')
      ..headers.set(HttpHeaders.contentLengthHeader, bytes.length.toString())
      ..headers.set('Content-Disposition', 'attachment; filename*=UTF-8\'\'$encodedName')
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-cache')
      ..add(bytes);
    await request.response.close();
    await zipFile.delete();
    print('\nDownload the file: $zipName');
  } catch (e) {
    request.response
      ..statusCode = HttpStatus.internalServerError
      ..write('Error: $e')
      ..close();
  }
}

Future<void> handleUpload(HttpRequest request) async {
  try {
    if (request.headers.contentType?.mimeType == 'multipart/form-data') {
      final boundary = request.headers.contentType!.parameters['boundary']!;
      final transformer = MimeMultipartTransformer(boundary);
      final parts = await transformer.bind(request).toList();
      String? jsonString;
      List<int>? zipBytes;
      String? fileName;
      for (var part in parts) {
        final headers = part.headers;
        final contentDisposition = headers['content-disposition'] ?? '';
        final content = await part.fold<List<int>>([], (a, b) => a..addAll(b));
        if (contentDisposition.contains('name="file"')) {
          final match = RegExp(r'filename="([^"]+)"').firstMatch(contentDisposition);
          fileName = match != null ? match.group(1) : 'upload_${DateTime.now().millisecondsSinceEpoch}.zip';
          zipBytes = content;
        } else if (contentDisposition.contains('name="params"')) {
          jsonString = utf8.decode(content);
        }
      }
      late String game;
      late String profile;
      if (jsonString != null) {
        final Map<String, dynamic> params = json.decode(jsonString);
        game = params['game'];
        profile = params['profile'];
      }
      late String save;
      if (zipBytes != null) {
        final Directory tempDir = Directory.systemTemp;
        final String zipPath = [tempDir.path, fileName].join(Platform.pathSeparator);
        final zipFile = File(zipPath);
        await zipFile.writeAsBytes(zipBytes);
        final targetPath = ['SaveLoad', game, profile].join(Platform.pathSeparator);
        save = await extractZip(zipPath, targetPath);
        await zipFile.delete();
        print('\nUpload the file: $fileName');
      }
      request.response
        ..statusCode = HttpStatus.ok
        ..write(save)
        ..close();
    } else {
      request.response
        ..statusCode = HttpStatus.badRequest
        ..write('Only accepts multipart/form-data format')
        ..close();
    }
  } catch (e) {
    request.response
      ..statusCode = HttpStatus.internalServerError
      ..write('Error: $e')
      ..close();
  }
}

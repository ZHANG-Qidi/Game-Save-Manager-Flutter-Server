import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'saveload_core.dart';

const staticFilesDir = 'web';
void main() async {
  await pathSeparatorGet();
  final currentDir = Directory.current.path;
  print('Current working directory: $currentDir');
  final staticDir = Directory([currentDir, staticFilesDir].join(Platform.pathSeparator));
  print('Static files directory: ${staticDir.absolute.path}');
  if (!await staticDir.exists()) {
    print('Warning: The static file directory does not exist! Please create:${staticDir.path}');
  }
  final server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
  print('Server running on:');
  print(' - Local:\nhttp://localhost:${server.port}');
  final interfaces = await NetworkInterface.list();
  final lanIPs = interfaces
      .expand((interface) => interface.addresses)
      .where((addr) => addr.type == InternetAddressType.IPv4 && !addr.isLoopback)
      .map((addr) => addr.address)
      .toList();
  if (lanIPs.isNotEmpty) {
    print(' - LAN:\n${lanIPs.map((ip) => 'http://$ip:${server.port}').join('\n')}');
  } else {
    print(' - LAN:    No available IPv4 addresses found');
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
    print('id: ${DateTime.fromMillisecondsSinceEpoch(id)}');
    print('method: $method');
    print('params: $params');
    if (method == null) {
      sendErrorResponse(request.response, -32600, 'Method is required');
      return;
    }
    final result = await _executeMethod(method, params);
    print('result: $result\n');
    sendSuccessResponse(request.response, id, result);
  } catch (e) {
    sendErrorResponse(request.response, -32700, 'Parse error: $e');
  }
}

Future<dynamic> _executeMethod(String method, dynamic params) async {
  dynamic result;
  switch (method) {
    case 'gameListFunc':
      result = await gameListFunc();
      break;
    case 'profileListFunc':
      final (profileList, folder, file) = await profileListFunc(params[0]);
      result = [profileList, folder, file];
      break;
    case 'saveListFunc':
      result = await saveListFunc(game: params[0], profile: params[1]);
      break;
    case 'gameDelete':
      result = await gameDelete(params[0]);
      break;
    case 'profileNew':
      result = await profileNew(game: params[0], profile: params[1]);
      break;
    case 'profileDelete':
      result = await profileDelete(game: params[0], profile: params[1]);
      break;
    case 'saveNew':
      result = await saveNew(
        game: params[0],
        profile: params[1],
        saveFolder: params[2],
        saveFile: params[3],
        comment: params[4],
      );
      break;
    case 'saveDelete':
      result = await saveDelete(
        game: params[0],
        profile: params[1],
        saveFolder: params[2],
        saveFile: params[3],
        save: params[4],
      );
      break;
    case 'saveLoad':
      result = await saveLoad(game: params[0], profile: params[1], saveFolder: params[2], saveFile: params[3], save: params[4]);
      break;
    case 'pathSeparator':
      result = Platform.pathSeparator;
      break;
    case 'listDirectoryFiles':
      result = await listDirectoryFiles(params[0]);
      break;
    case 'listDirectorySubDirectories':
      result = await listDirectorySubDirectories(params[0]);
      break;
    case 'getAppDataPath':
      result = await getAppDataPath();
      break;
    case 'getRootDirectory':
      result = await getRootDirectory();
      break;
    case 'gameNew':
      result = await gameNew(game: params[0], saveFolder: params[1], saveFile: params[2]);
      break;
    default:
      throw UnsupportedError('Function $method is not supported');
  }
  return result;
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

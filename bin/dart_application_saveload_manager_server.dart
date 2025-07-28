import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'saveload_core.dart';
import 'package:mime/mime.dart';

const staticFilesDir = 'web';
void main() async {
  final port = int.parse(Platform.environment['PORT'] ?? '8000');
  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  await infoPrint(server);
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

Future<void> infoPrint(HttpServer server) async {
  final currentDir = Directory.current.path;
  print('Current working directory: $currentDir');
  final staticDir = Directory([currentDir, staticFilesDir].join(Platform.pathSeparator));
  print('Static files directory: ${staticDir.absolute.path}');
  if (!await staticDir.exists()) {
    print('Warning: The static file directory does not exist! Please create:${staticDir.path}');
  }
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
  switch (method) {
    case 'gameListFunc':
      return await gameListFunc();
    case 'profileListFunc':
      final (profileList, folder, file) = await profileListFunc(params[0]);
      return [profileList, folder, file];
    case 'saveListFunc':
      return await saveListFunc(game: params[0], profile: params[1]);
    case 'gameDelete':
      return await gameDelete(params[0]);
    case 'profileNew':
      return await profileNew(game: params[0], profile: params[1]);
    case 'profileDelete':
      return await profileDelete(game: params[0], profile: params[1]);
    case 'saveNew':
      return await saveNew(game: params[0], profile: params[1], saveFolder: params[2], saveFile: params[3], comment: params[4]);
    case 'saveDelete':
      return await saveDelete(game: params[0], profile: params[1], saveFolder: params[2], saveFile: params[3], save: params[4]);
    case 'saveLoad':
      return await saveLoad(game: params[0], profile: params[1], saveFolder: params[2], saveFile: params[3], save: params[4]);
    case 'pathSeparator':
      return Platform.pathSeparator;
    case 'listDirectoryFilesNames':
      return await listDirectoryFilesNames(params[0]);
    case 'listDirectorySubDirectoriesNames':
      return await listDirectorySubDirectoriesNames(params[0]);
    case 'getAppDataPath':
      return await getAppDataPath();
    case 'getRootDirectory':
      return await getRootDirectory();
    case 'gameNew':
      return await gameNew(game: params[0], saveFolder: params[1], saveFile: params[2]);
    default:
      throw UnsupportedError('Function $method is not supported');
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
    final String zipPath = '${tempDir.path}/$save.zip';
    final savePath = ['SaveLoad', game, profile, save].join(Platform.pathSeparator);
    await compressToZip(savePath, zipPath);
    final File zipFile = File(zipPath);
    final List<int> bytes = await zipFile.readAsBytes();
    request.response
      ..headers.set(HttpHeaders.contentTypeHeader, 'application/zip')
      ..headers.set('Content-Disposition', 'attachment; filename="$save.zip"')
      ..add(bytes);
    await request.response.close();
    await zipFile.delete();
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
          // print('Received zip file, size: ${zipBytes.length}');
        } else if (contentDisposition.contains('name="params"')) {
          jsonString = utf8.decode(content);
          // print('Received parameter: $jsonString');
        }
      }
      late String game;
      late String profile;
      if (jsonString != null) {
        final Map<String, dynamic> params = json.decode(jsonString);
        // print('Parameter content: $params');
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
        // print('The file has been saved to: $zipPath');
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

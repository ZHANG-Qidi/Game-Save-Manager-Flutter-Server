import 'dart:io';
import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';
import 'package:mime/mime.dart';
import 'package:http_parser/http_parser.dart';
import 'saveload_core.dart';

const staticFilesDir = 'web';
final staticHandler = createStaticHandler(staticFilesDir, defaultDocument: 'index.html', serveFilesOutsidePath: false);
// Configure routes.
final _router = Router()
  ..get('/echo/<message>', _echoHandler)
  ..post('/download', handleDownload)
  ..post('/jsonrpc', handleJsonRpc)
  ..post('/upload', handleUpload);
Response _echoHandler(Request request) {
  final message = request.params['message'];
  return Response.ok('$message\n');
}

final Map<String, String> corsHeadersRule = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
  'Access-Control-Allow-Headers': 'Origin, Content-Type, Accept, Authorization',
  'Access-Control-Allow-Credentials': 'true',
  'Access-Control-Max-Age': '86400',
};

Middleware corsHeaders() {
  return (Handler handler) {
    return (Request request) async {
      final response = await handler(request);
      return response.change(headers: {...response.headers, ...corsHeadersRule});
    };
  };
}

Middleware corsMiddleware = (Handler handler) {
  return (Request request) async {
    if (request.method == 'OPTIONS') {
      return Response(HttpStatus.noContent, headers: corsHeadersRule);
    }

    final response = await handler(request);
    return response.change(headers: {...response.headers, ...corsHeadersRule});
  };
};

Future<Response> handleJsonRpc(Request request) async {
  try {
    final content = await request.readAsString();
    final jsonData = jsonDecode(content) as Map<String, dynamic>;
    if (jsonData['jsonrpc'] != '2.0') {
      return _sendErrorResponse(-32600, 'Invalid Request', jsonData['id']);
    }
    final method = jsonData['method'] as String?;
    final params = jsonData['params'] ?? [];
    final id = jsonData['id'];
    if (id is int) {
      print('id: ${DateTime.fromMillisecondsSinceEpoch(id)}');
    } else {
      print('id: $id');
    }
    print('method: $method');
    print('params: $params');
    if (method == null) {
      return _sendErrorResponse(-32600, 'Method is required', id);
    }
    final result = await _executeMethod(method, params);
    print('result: $result\n');
    return _sendSuccessResponse(id, result);
  } catch (e) {
    return _sendErrorResponse(-32700, 'Parse error: $e', null);
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
    case 'listDirectoryFiles':
      return await listDirectoryFiles(params[0]);
    case 'listDirectorySubDirectories':
      return await listDirectorySubDirectories(params[0]);
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

Response _sendSuccessResponse(dynamic id, dynamic result) {
  final json = jsonEncode({'jsonrpc': '2.0', 'result': result, 'id': id});
  return Response.ok(json, headers: {'Content-Type': 'application/json'});
}

Response _sendErrorResponse(int code, String message, dynamic id) {
  final json = jsonEncode({
    'jsonrpc': '2.0',
    'error': {'code': code, 'message': message},
    'id': id,
  });
  return Response.ok(json, headers: {'Content-Type': 'application/json'});
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

void main(List<String> args) async {
  // Use any available host or container IP (usually `0.0.0.0`).
  final ip = InternetAddress.anyIPv4;
  final handler = Cascade().add(staticHandler).add(_router.call).handler;
  // Configure a pipeline that logs requests.
  final pipeline = Pipeline()
      // .addMiddleware(corsMiddleware)
      .addMiddleware(logRequests())
      // .addMiddleware(corsHeaders())
      .addHandler(handler);
  // For running in containers, we respect the PORT environment variable.
  final port = int.parse(Platform.environment['PORT'] ?? '8000');
  final server = await serve(pipeline, ip, port);
  print('Server listening on port ${server.port}');
  infoPrint(server);
}

Future<Response> handleDownload(Request request) async {
  try {
    final content = await request.readAsString();
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
    final headers = {
      HttpHeaders.contentTypeHeader: 'application/zip',
      'Content-Disposition': 'attachment; filename="$save.zip"',
    };
    await zipFile.delete();
    return Response.ok(bytes, headers: headers);
  } catch (e) {
    return Response.internalServerError(body: 'Error: $e');
  }
}

Future<Response> handleUpload(Request request) async {
  try {
    final contentType = request.headers['content-type'];
    if (contentType != null && contentType.startsWith('multipart/form-data')) {
      final header = MediaType.parse(contentType);
      final boundary = header.parameters['boundary'];
      if (boundary == null) {
        return Response.badRequest(body: 'Missing boundary in Content-Type');
      }
      final transformer = MimeMultipartTransformer(boundary);
      final parts = await transformer.bind(request.read()).toList();
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
      if (zipBytes != null) {
        final Directory tempDir = Directory.systemTemp;
        final String zipPath = [tempDir.path, fileName].join(Platform.pathSeparator);
        final zipFile = File(zipPath);
        await zipFile.writeAsBytes(zipBytes);
        final targetPath = ['SaveLoad', game, profile].join(Platform.pathSeparator);
        await extractZip(zipPath, targetPath);
        await zipFile.delete();
      }
      return Response.ok('Upload successful!');
    } else {
      return Response(HttpStatus.badRequest, body: 'Only accepts multipart/form-data format');
    }
  } catch (e) {
    return Response(HttpStatus.internalServerError, body: 'Error: $e');
  }
}

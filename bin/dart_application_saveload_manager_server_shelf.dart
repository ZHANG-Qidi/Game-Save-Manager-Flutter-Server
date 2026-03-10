import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';
import 'package:mime/mime.dart';
import 'package:http_parser/http_parser.dart';
import 'saveload_core_server.dart';
import 'saveload_core_server_mdns.dart';
import 'saveload_core_file_system.dart';

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

Middleware noCacheForBootstrap() {
  return (Handler inner) {
    return (Request req) async {
      final res = await inner(req);
      if (req.url.path == 'flutter_bootstrap.js') {
        return res.change(headers: {...res.headers, 'Cache-Control': 'no-cache, no-store, must-revalidate'});
      }
      return res;
    };
  };
}

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
      print('\nid: ${DateTime.fromMillisecondsSinceEpoch(id)}');
    } else {
      print('id: $id');
    }
    print('method: $method');
    print('params: $params');
    if (method == null) {
      return _sendErrorResponse(-32600, 'Method is required', id);
    }
    final result = await executeMethod(method, params);
    print('result: $result');
    return _sendSuccessResponse(id, result);
  } catch (e) {
    return _sendErrorResponse(-32700, 'Parse error: $e', null);
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

void main(List<String> args) async {
  try {
    // Use any available host or container IP (usually `0.0.0.0`).
    final ip = InternetAddress.anyIPv4;
    final handler = Cascade().add(staticHandler).add(_router.call).handler;
    // Configure a pipeline that logs requests.
    final pipeline = Pipeline()
        // .addMiddleware(corsMiddleware)
        // .addMiddleware(noCacheForBootstrap())
        .addMiddleware(logRequests())
        // .addMiddleware(corsHeaders())
        .addHandler(handler);
    // For running in containers, we respect the PORT environment variable.
    final port = int.parse(Platform.environment['PORT'] ?? '8000');
    final server = await serve(pipeline, ip, port);
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
    await Completer<void>().future;
  } catch (e) {
    print('❌ Server startup failed: $e');
    exit(1);
  }
}

Future<Response> handleDownload(Request request) async {
  try {
    final content = await request.readAsString();
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
    final headers = {
      HttpHeaders.contentTypeHeader: 'application/zip',
      HttpHeaders.contentLengthHeader: bytes.length.toString(),
      'Content-Disposition': 'attachment; filename*=UTF-8\'\'$encodedName',
      HttpHeaders.cacheControlHeader: 'no-cache',
    };
    await zipFile.delete();
    print('\nDownload the file: $zipName');
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
      return Response.ok(save);
    } else {
      return Response(HttpStatus.badRequest, body: 'Only accepts multipart/form-data format');
    }
  } catch (e) {
    return Response(HttpStatus.internalServerError, body: 'Error: $e');
  }
}

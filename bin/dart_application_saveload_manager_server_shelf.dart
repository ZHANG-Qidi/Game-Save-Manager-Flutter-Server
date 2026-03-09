import 'dart:io';
import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';
import 'package:mime/mime.dart';
import 'package:http_parser/http_parser.dart';
import 'saveload_core.dart';
import 'package:mdns_dart/mdns_dart.dart';
import 'dart:async';

Future<bool> isIpReachable(InternetAddress ip) async {
  final isLanIp =
      ip.address.contains(RegExp(r'^192\.168\.(?!137\.|56\.)\d+\.\d+$')) ||
      ip.address.contains(RegExp(r'^10\.\d+\.\d+\.\d+$')) ||
      ip.address.contains(RegExp(r'^172\.(1[6-9]|2\d|3[0-1])\.\d+\.\d+$'));
  if (!isLanIp) return false;
  ServerSocket? serverSocket;
  try {
    serverSocket = await ServerSocket.bind(ip, 9090, shared: true);
    return true;
  } catch (e) {
    if (e.toString().contains('address already in use')) {
      return true;
    }
    return false;
  } finally {
    serverSocket?.close();
  }
}

Future<List<MDNSServer>> startMDNSServer(int port) async {
  print('Starting mDNS server...');
  final interfaces = await NetworkInterface.list();
  List<InternetAddress> localIPs = [];
  final excludeInterfaceNames = ['docker', 'veth', 'vmware', 'hyper-v', 'bluetooth', 'tun', 'tap', 'loopback'];
  for (final interface in interfaces) {
    if (excludeInterfaceNames.any((name) => interface.name.toLowerCase().contains(name))) continue;
    for (final addr in interface.addresses) {
      if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
        if (await isIpReachable(addr)) {
          localIPs.add(addr);
          print('✅ Found valid IP: ${addr.address} (interface: ${interface.name})');
        } else {
          print('❌ Skip unreachable IP: ${addr.address} (interface: ${interface.name})');
        }
      }
    }
  }
  if (localIPs.isEmpty) {
    print('❌ Could not find any valid network interface (IPv4, non-loopback, reachable)');
    return [];
  }
  List<MDNSServer> mDNSservers = [];
  for (final ip in localIPs) {
    final instanceName = 'Dart Test Server [${ip.address}]';
    try {
      final service = await MDNSService.create(
        instance: instanceName,
        service: '_http._tcp',
        port: port,
        ips: [ip],
        txt: ['path=/api', 'interface=${ip.address}'],
      );
      final mDNSserver = MDNSServer(MDNSServerConfig(zone: service));
      await mDNSserver.start();
      mDNSservers.add(mDNSserver);
      print('📌 mDNS Service: $instanceName bound to IP: ${ip.address} (port: ${service.port})');
    } catch (e) {
      print('❌ Failed to create service for ${ip.address}: $e');
    }
  }
  print('✅ All mDNS servers started!');
  return mDNSservers;
}

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
    final result = await _executeMethod(method, params);
    print('result: $result');
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
    case 'saveRename':
      return await saveRename(
        game: params[0],
        profile: params[1],
        saveFolder: params[2],
        saveFile: params[3],
        save: params[4],
        name: params[5],
      );
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
    case 'listMdnsServer':
      return await listMdnsServer();
    case 'syncSaveToReceiver':
      return await syncSaveToReceiver(
        game: params[0],
        profile: params[1],
        save: params[2],
        url: params[3],
        port: params[4].toString(),
      );
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

Future<void> stopAllServices(HttpServer shelfServer, List<MDNSServer> mdnsServers) async {
  print('\n=== Stopping Services ===');
  await shelfServer.close(force: true);
  print('🛑 Shelf server stopped');
  for (final server in mdnsServers) {
    try {
      await server.stop();
    } catch (e) {
      print('⚠️ Failed to stop mDNS server: $e');
    }
  }
  print('🛑 All mDNS servers stopped');
  exit(0);
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
    final shelfServer = await serve(pipeline, ip, port);
    print('Server listening on port ${shelfServer.port}');
    await infoPrint(shelfServer);
    final mdnsServers = await startMDNSServer(port);
    ProcessSignal.sigint.watch().listen((_) async {
      await stopAllServices(shelfServer, mdnsServers);
    });
    if (!Platform.isWindows) {
      ProcessSignal.sigterm.watch().listen((_) async {
        await stopAllServices(shelfServer, mdnsServers);
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

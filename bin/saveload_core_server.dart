import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:mdns_dart/mdns_dart.dart';
import 'saveload_core_server_mdns.dart';
import 'saveload_core_file_system.dart';
import 'saveload_core_save_system.dart';

const staticFilesDir = 'web';

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

Future<dynamic> executeMethod(String method, List<dynamic> params) async {
  try {
    final List<String> paramsString = params.map((e) => e.toString()).toList();
    switch (method) {
      case 'gameListFunc':
        return await gameListFunc();
      case 'profileListFunc':
        final (profileList, folder, file) = await profileListFunc(paramsString[0]);
        return [profileList, folder, file];
      case 'saveListFunc':
        return await saveListFunc(game: paramsString[0], profile: paramsString[1]);
      case 'gameDelete':
        return await gameDelete(paramsString[0]);
      case 'profileNew':
        return await profileNew(game: paramsString[0], profile: paramsString[1]);
      case 'profileDelete':
        return await profileDelete(game: paramsString[0], profile: paramsString[1]);
      case 'saveNew':
        return await saveNew(
          game: paramsString[0],
          profile: paramsString[1],
          saveFolder: paramsString[2],
          saveFile: paramsString[3],
          comment: paramsString[4],
        );
      case 'saveDelete':
        return await saveDelete(
          game: paramsString[0],
          profile: paramsString[1],
          saveFolder: paramsString[2],
          saveFile: paramsString[3],
          save: paramsString[4],
        );
      case 'saveRename':
        return await saveRename(
          game: paramsString[0],
          profile: paramsString[1],
          saveFolder: paramsString[2],
          saveFile: paramsString[3],
          save: paramsString[4],
          name: paramsString[5],
        );
      case 'saveLoad':
        return await saveLoad(
          game: paramsString[0],
          profile: paramsString[1],
          saveFolder: paramsString[2],
          saveFile: paramsString[3],
          save: paramsString[4],
        );
      case 'pathSeparator':
        return Platform.pathSeparator;
      case 'listDirectoryFilesNames':
        return await listDirectoryFilesNames(paramsString[0]);
      case 'listDirectorySubDirectoriesNames':
        return await listDirectorySubDirectoriesNames(paramsString[0]);
      case 'getAppDataPath':
        return await getAppDataPath();
      case 'getRootDirectory':
        return await getRootDirectory();
      case 'gameNew':
        return await gameNew(game: paramsString[0], saveFolder: paramsString[1], saveFile: paramsString[2]);
      case 'funcListMdnsServer':
        return await funcListMdnsServer();
      case 'handleSync':
        return await handleSync(
          game: paramsString[0],
          profile: paramsString[1],
          save: paramsString[2],
          url: paramsString[3],
          port: paramsString[4],
        );
      default:
        throw UnsupportedError('Function $method is not supported');
    }
  } catch (e) {
    throw Exception('Json RPC execute error, function: $method, error: $e');
  }
}

Future<void> stopAllServices(HttpServer server, List<MDNSServer> mdnsServers) async {
  print('\n=== Stopping Services ===');
  await server.close(force: true);
  print('🛑 HttpServer stopped');
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

Future<String> handleSync({
  required String game,
  required String profile,
  required String save,
  required String url,
  required String port,
}) async {
  String baseUrl = url;
  if (!url.startsWith(RegExp(r'^http(s)?://'))) baseUrl = 'http://$url';
  final receiverUploadUrl = '$baseUrl:$port/upload';
  File? tempZipFile;
  try {
    final zipName = [game, profile, '$save.zip'].join('_');
    final tempDir = Directory.systemTemp;
    final savePath = ['SaveLoad', game, profile, save].join(Platform.pathSeparator);
    final String zipPath = [tempDir.path, zipName].join(Platform.pathSeparator);
    await compressToZip(savePath, zipPath);
    tempZipFile = File(zipPath);
    final bytes = await tempZipFile.readAsBytes();
    final Map<String, dynamic> jsonParams = {'game': game, 'profile': profile};
    final request = http.MultipartRequest('POST', Uri.parse(receiverUploadUrl))
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: zipName))
      ..fields['params'] = json.encode(jsonParams);
    final response = await request.send();
    if (response.statusCode == 200) {
      return await response.stream.bytesToString();
    } else {
      return 'NG';
    }
  } catch (e) {
    throw Exception('Failed to sync save: $e');
  } finally {
    if (tempZipFile != null && await tempZipFile.exists()) {
      await tempZipFile.delete();
    }
  }
}

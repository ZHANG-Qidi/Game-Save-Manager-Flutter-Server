import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:ini/ini.dart';
import 'package:intl/intl.dart';
import 'package:mdns_dart/mdns_dart.dart';
import 'package:path/path.dart' as path_lib;
import 'package:archive/archive_io.dart';
// import 'package:file_selector/file_selector.dart';
import 'saveload_core_common.dart';

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

Future<dynamic> executeMethod(String method, dynamic params) async {
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
    case 'funcListMdnsServer':
      return await funcListMdnsServer();
    case 'handleSync':
      return await handleSync(game: params[0], profile: params[1], save: params[2], url: params[3], port: params[4].toString());
    default:
      throw UnsupportedError('Function $method is not supported');
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


Future<void> safeCreateFolder(Directory dir) async {
  try {
    if (await dir.exists()) {
      // print('Directory exists');
      return;
    }
    await dir.create(recursive: true);
    // print('New directory success: ${dir.path}');
  } catch (e) {
    throw Exception('New directory failed: $e');
  }
}

Future<void> copyDirectory(Directory source, Directory destination) async {
  try {
    await destination.create(recursive: true);
    await for (final entity in source.list()) {
      final newDestination = Directory(
        [destination.path, entity.path.split(Platform.pathSeparator).last].join(Platform.pathSeparator),
      );
      if (entity is File) {
        await entity.copy(newDestination.path);
      } else if (entity is Directory) {
        await copyDirectory(entity, newDestination);
      }
    }
  } catch (e) {
    throw Exception('Copy directory error with: $e');
  }
}

Future<List<FileSystemEntity>> listDirectoryContents(Directory dir) async {
  try {
    if (!await dir.exists()) {
      throw Exception('Directory does not exist: ${dir.path}');
    }
    final contents = <FileSystemEntity>[];
    await for (final entity in dir.list()) {
      contents.add(entity);
    }
    return contents;
  } catch (e) {
    throw Exception('Failed to list contentes: $e');
  }
}

Future<List<String>> listDirectoryFiles(String dirString) async {
  try {
    final dir = Directory(dirString);
    if (!await dir.exists()) {
      throw Exception('Directory does not exist: ${dir.path}');
    }
    final files = <File>[];
    await for (final entity in dir.list()) {
      if (entity is File) {
        files.add(entity);
      }
    }
    return files.map((file) => file.path).toList();
  } catch (e) {
    throw Exception('Failed to list files: $e');
  }
}

Future<List<String>> listDirectoryFilesNames(String dirString) async {
  try {
    final fileList = await listDirectoryFiles(dirString);
    final fileNames = fileList.map((path) => _getFileName(path)).toList();
    return fileNames;
  } catch (e) {
    throw Exception('listDirectoryFilesNames error with: $e');
  }
}

Future<List<String>> listDirectorySubDirectories(String dirString) async {
  try {
    final dir = Directory(dirString);
    if (!await dir.exists()) {
      throw Exception('Directory does not exist: ${dir.path}');
    }
    final directories = <Directory>[];
    await for (final entity in dir.list()) {
      if (entity is Directory) {
        directories.add(entity);
      }
    }
    return directories.map((directory) => directory.path).toList();
  } catch (e) {
    throw Exception('Failed to list subdirectories: $e');
  }
}

Future<List<String>> listDirectorySubDirectoriesNames(String dirString) async {
  try {
    final dirList = await listDirectorySubDirectories(dirString);
    final dirNames = dirList.map((path) => _getFileName(path)).toList();
    return dirNames;
  } catch (e) {
    throw Exception('listDirectorySubDirectoriesNames error with: $e');
  }
}

Future<List<File>> listDirectoryAllFiles(Directory dir) async {
  try {
    if (!await dir.exists()) {
      throw Exception('Directory does not exist: ${dir.path}');
    }
    final files = <File>[];
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File) {
        files.add(entity);
      }
    }
    return files;
  } catch (e) {
    throw Exception('Directory traversal error: $e');
  }
}

Future<List<File>> listDirectoryIniFiles(Directory dir) async {
  try {
    final files = <File>[];
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File && entity.path.toLowerCase().endsWith('.ini')) {
        files.add(entity);
      }
    }
    return files;
  } catch (e) {
    throw Exception('Directory traversal error: $e');
  }
}

Future<Map> readIniFile(String game) async {
  try {
    final file = File(['SaveLoad', game, 'Path.ini'].join(Platform.pathSeparator));
    final content = await file.readAsString();
    final config = Config.fromString(content);
    var values = {};
    values['folder'] = config.get('path', 'folder');
    values['file'] = config.get('path', 'file');
    return values;
  } on FileSystemException catch (e) {
    throw Exception('File system error with: $e');
  } catch (e) {
    throw Exception('Read ini file error with: $e');
  }
}

Future<void> writeIniFile({required String game, String saveFolder = '', String saveFile = ''}) async {
  try {
    final config = Config();
    config.addSection("path");
    config.set("path", "folder", saveFolder);
    config.set("path", "file", saveFile);
    final output = config.toString();
    final file = File(['SaveLoad', game, 'Path.ini'].join(Platform.pathSeparator));
    await file.writeAsString(output);
  } on FileSystemException catch (e) {
    throw Exception('File system error with: $e');
  } catch (e) {
    throw Exception('Write ini file error with: $e');
  }
}

Future<List<String>> gameListFunc() async {
  try {
    final dir = Directory('SaveLoad');
    await safeCreateFolder(dir);
    final saveList = await listDirectorySubDirectoriesNames(dir.path);
    return saveList;
  } catch (e) {
    throw Exception('Get the list of Games error: $e');
  }
}

Future<(List<String>, String, String)> profileListFunc(String game) async {
  try {
    if (game.isEmpty) {
      return (List<String>.empty(), '', '');
    }
    final dir = Directory(['SaveLoad', game].join(Platform.pathSeparator));
    final profileList = await listDirectorySubDirectoriesNames(dir.path);
    final pathIni = await readIniFile(game);
    final String folder = pathIni['folder'];
    final String file = pathIni['file'];
    return (profileList, folder, file);
  } catch (e) {
    throw Exception('Get the list of Profiles error: $e');
  }
}

Future<List<String>> saveListFunc({required String game, required String profile}) async {
  try {
    if (game.isEmpty || profile.isEmpty) {
      return List<String>.empty();
    }
    final dir = Directory(['SaveLoad', game, profile].join(Platform.pathSeparator));
    var contents = await listDirectoryContents(dir);
    List<String> contentsString = contents.map((dir) => dir.path).toList();
    contentsString = await saveListFuncRemove(contentsString);
    final saveList = contentsString.map((path) => _getFileName(path)).toList();
    return saveList;
  } catch (e) {
    throw Exception('Get the list of sub directory error: $e');
  }
}

Future<List<String>> saveListFuncRemove(List<String> contentsString) async {
  List<String> contentsStringToRemove = [];
  contentsString.sort((a, b) => b.compareTo(a));
  Map<String, int> commentMap = {};
  for (final content in contentsString) {
    final comment = getComment(content);
    commentMap[comment] = commentMap[comment] ?? 0;
    commentMap[comment] = commentMap[comment]! + 1;
    if (commentMap[comment]! > 3) {
      contentsStringToRemove.add(content);
      final type = await FileSystemEntity.type(content);
      if (type == FileSystemEntityType.file) {
        await File(content).delete();
      } else if (type == FileSystemEntityType.directory) {
        await Directory(content).delete(recursive: true);
      }
    }
  }
  for (final content in contentsStringToRemove) {
    contentsString.removeWhere((item) => item == content);
  }
  // print('commentMap = ${commentMap.toString()}');
  return contentsString;
}

Future<String> gameNew({required String game, String saveFolder = '', String saveFile = ''}) async {
  try {
    if (game.isEmpty) {
      return 'NG';
    }
    final dir = Directory(['SaveLoad', game].join(Platform.pathSeparator));
    await safeCreateFolder(dir);
    await writeIniFile(game: game, saveFolder: saveFolder, saveFile: saveFile);
    return 'OK';
  } catch (e) {
    throw Exception('Game new error with: $e');
  }
}

Future<String> gameDelete(String game) async {
  final dir = Directory(['SaveLoad', game].join(Platform.pathSeparator));
  try {
    if (game.isEmpty) {
      return 'NG';
    }
    if (!await dir.exists()) {
      throw Exception('Directory does not exist: ${dir.path}');
    }
    await dir.delete(recursive: true);
    // print("Game delete success: ${dir.path}");
    return 'OK';
  } catch (e) {
    throw Exception('Game delete error with: $e');
  }
}

Future<String> profileNew({required String game, required String profile}) async {
  try {
    if (game.isEmpty || profile.isEmpty) {
      return 'NG';
    }
    await safeCreateFolder(Directory(['SaveLoad', game, profile].join(Platform.pathSeparator)));
    return 'OK';
  } catch (e) {
    throw Exception('Profile new error with: $e');
  }
}

Future<String> profileDelete({required String game, required String profile}) async {
  try {
    if (game.isEmpty || profile.isEmpty) {
      return 'NG';
    }
    final dir = Directory(['SaveLoad', game, profile].join(Platform.pathSeparator));
    if (!await dir.exists()) {
      throw Exception('Directory does not exist: ${dir.path}');
    }
    await dir.delete(recursive: true);
    // print("Profile delete success: ${dir.path}");
    return 'OK';
  } catch (e) {
    throw Exception('Profile delete error with: $e');
  }
}

Future<String> saveNew({
  required String game,
  required String profile,
  required String saveFolder,
  required String saveFile,
  required String comment,
}) async {
  try {
    if (game.isEmpty || profile.isEmpty) {
      return 'NG';
    }
    DateFormat formatter = DateFormat('yyyy-MM-dd HH-mm-ss');
    DateTime modifiedTimeLast = DateTime(1970);
    if (saveFolder.isNotEmpty) {
      final dir = Directory(saveFolder);
      final fileList = await listDirectoryAllFiles(dir);
      for (final entity in fileList) {
        final DateTime modifiedTime = await entity.lastModified();
        if (modifiedTime.isAfter(modifiedTimeLast)) {
          modifiedTimeLast = modifiedTime;
        }
      }
      final String strModifiedTimeLast = formatter.format(modifiedTimeLast);
      String targetFolder;
      if (comment.isEmpty) {
        targetFolder = ['SaveLoad', game, profile, strModifiedTimeLast].join(Platform.pathSeparator);
      } else {
        targetFolder = ['SaveLoad', game, profile, '$strModifiedTimeLast@$comment'].join(Platform.pathSeparator);
      }
      final sourceDir = Directory(saveFolder);
      final destDir = Directory(targetFolder);
      if (!await destDir.exists()) {
        await copyDirectory(sourceDir, destDir);
      }
      return _getFileName(targetFolder);
    }
    if (saveFile.isNotEmpty) {
      modifiedTimeLast = await File(saveFile).lastModified();
      final String strModifiedTimeLast = formatter.format(modifiedTimeLast);
      String targetFile;
      if (comment.isEmpty) {
        targetFile = [
          'SaveLoad',
          game,
          profile,
          strModifiedTimeLast + path_lib.extension(saveFile),
        ].join(Platform.pathSeparator);
      } else {
        targetFile = [
          'SaveLoad',
          game,
          profile,
          '$strModifiedTimeLast@$comment${path_lib.extension(saveFile)}',
        ].join(Platform.pathSeparator);
      }
      final sourceFile = File(saveFile);
      final destFile = File(targetFile);
      if (!await destFile.exists()) {
        await sourceFile.copy(destFile.path);
      }
      return _getFileName(targetFile);
    }
    return 'NG';
  } catch (e) {
    throw Exception('Save new error with: $e');
  }
}

Future<String> saveDelete({
  required String game,
  required String profile,
  required String saveFolder,
  required String saveFile,
  required String save,
}) async {
  try {
    if (game.isEmpty || profile.isEmpty || save.isEmpty) {
      return 'NG';
    }
    final savePath = ['SaveLoad', game, profile, save].join(Platform.pathSeparator);
    if (saveFolder.isNotEmpty) {
      final dir = Directory(savePath);
      if (!await dir.exists()) {
        throw Exception('Directory does not exist: ${dir.path}');
      }
      await dir.delete(recursive: true);
      // print("Save delete success: ${dir.path}");
    }
    if (saveFile.isNotEmpty) {
      final file = File(savePath);
      if (!await file.exists()) {
        throw Exception('File does not exist: ${file.path}');
      }
      await file.delete();
      // print("Save delete success: ${file.path}");
    }
    return 'OK';
  } catch (e) {
    throw Exception('Save delete error with: $e');
  }
}

Future<String> saveRename({
  required String game,
  required String profile,
  required String saveFolder,
  required String saveFile,
  required String save,
  required String name,
}) async {
  try {
    if (game.isEmpty || profile.isEmpty || save.isEmpty) {
      return 'NG';
    }
    final oldPath = ['SaveLoad', game, profile, save].join(Platform.pathSeparator);
    final newPath = ['SaveLoad', game, profile, name].join(Platform.pathSeparator);
    if (saveFolder.isNotEmpty) {
      final oldDir = Directory(oldPath);
      if (!await oldDir.exists()) {
        throw Exception('Directory does not exist: ${oldDir.path}');
      }
      final newDir = Directory(newPath);
      if (await newDir.exists()) {
        throw Exception('New directory already exists: ${newDir.path}');
      }
      await oldDir.rename(newPath);
      // print("Directory rename success: ${oldDir.path} -> $newPath");
    }
    if (saveFile.isNotEmpty) {
      final oldFile = File(oldPath);
      if (!await oldFile.exists()) {
        throw Exception('File does not exist: ${oldFile.path}');
      }
      final newFile = File(newPath);
      if (await newFile.exists()) {
        throw Exception('New file already exists: ${newFile.path}');
      }
      await oldFile.rename(newPath);
      // print("File rename success: ${oldFile.path} -> $newPath");
    }
    return 'OK';
  } catch (e) {
    throw Exception('Save rename error with: $e');
  }
}

Future<String> saveLoad({
  required String game,
  required String profile,
  required String saveFolder,
  required String saveFile,
  required String save,
}) async {
  try {
    if (game.isEmpty || profile.isEmpty || save.isEmpty) {
      return 'NG';
    }
    final savePath = ['SaveLoad', game, profile, save].join(Platform.pathSeparator);
    if (saveFolder.isNotEmpty) {
      final sourcePath = Directory(savePath);
      final destPath = Directory(saveFolder);
      if (await destPath.exists()) {
        await destPath.delete(recursive: true);
      }
      await copyDirectory(sourcePath, destPath);
      // print("Save load success: ${sourcePath.path}");
      return 'OK';
    }
    if (saveFile.isNotEmpty) {
      final sourcePath = File(savePath);
      final destPath = File(saveFile);
      if (await destPath.exists()) {
        await destPath.delete();
      }
      await sourcePath.copy(destPath.path);
      // print("Save load success: ${sourcePath.path}");
      return 'OK';
    }
    return 'NG';
  } catch (e) {
    throw Exception('Save load error with: $e');
  }
}

Future<String> pathSeparatorGet() async {
  try {
    String result = Platform.pathSeparator;
    return result;
  } catch (e) {
    throw Exception('Error with: $e');
  }
}

Future<String> getAppDataPath() async {
  if (Platform.isWindows) {
    return Platform.environment['APPDATA'] ?? 'null';
  } else if (Platform.isMacOS) {
    return '${Platform.environment['HOME']}/Library/Application Support';
  } else if (Platform.isLinux) {
    final pathDeck = '${Platform.environment['HOME']}/.local/share/Steam/steamapps/compatdata';
    if (await FileSystemEntity.isDirectory(pathDeck)) {
      return pathDeck;
    }
    return Platform.environment['HOME'] ?? 'null';
  }
  return 'null';
}

/// Get available root/application directories for different OS
/// Windows: List of accessible drive letters; macOS: App Support directory; Linux: Steam compat dir (or home dir if not exists)
Future<List<String>> getRootDirectory() async {
  try {
    if (Platform.isWindows) {
      List<String> availableDrives = [];
      for (int i = 65; i <= 90; i++) {
        String driveLetter = String.fromCharCode(i);
        String path = '$driveLetter:${Platform.pathSeparator}';
        // Catch single drive access exceptions (e.g. inaccessible network drive), skip and continue
        try {
          if (await Directory(path).exists()) {
            availableDrives.add(path);
          }
        } catch (_) {
          continue;
        }
      }
      return availableDrives;
    } else if (Platform.isMacOS) {
      final homeDir = Platform.environment['HOME'];
      return homeDir != null ? ['$homeDir/Library/Application Support'] : [];
    } else if (Platform.isLinux) {
      final homeDir = Platform.environment['HOME'];
      if (homeDir == null) return [];
      final steamPath = '$homeDir/.local/share/Steam/steamapps/compatdata';
      if (await FileSystemEntity.isDirectory(steamPath)) {
        return [steamPath];
      }
      return [homeDir];
    }
    return [];
  } catch (e) {
    throw Exception('Error getting root directories: $e');
  }
}

Future<void> compressToZip(String sourcePath, String targetZipPath) async {
  try {
    final entityType = FileSystemEntity.typeSync(sourcePath);
    final encoder = ZipFileEncoder();
    encoder.create(targetZipPath);
    if (entityType == FileSystemEntityType.directory) {
      final inputDir = Directory(sourcePath);
      if (!inputDir.existsSync()) {
        throw Exception('The directory does not exist: $sourcePath');
      }
      await encoder.addDirectory(inputDir, includeDirName: true);
    } else if (entityType == FileSystemEntityType.file) {
      final inputFile = File(sourcePath);
      if (!inputFile.existsSync()) {
        throw Exception('The file does not exist: $sourcePath');
      }
      await encoder.addFile(inputFile);
    } else {
      throw Exception('The path is not a valid file or directory: $sourcePath');
    }
    await encoder.close();
  } catch (e) {
    throw Exception('Compression failed: $e');
  }
}

Future<String> extractZip(String zipFilePath, String destinationPath) async {
  try {
    final bytes = await File(zipFilePath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    final archiveFirstName = archive.first.name;
    for (final file in archive) {
      final filename = '$destinationPath${Platform.pathSeparator}${file.name}';
      if (file.isFile) {
        final outFile = File(filename)..createSync(recursive: true);
        await outFile.writeAsBytes(file.content as List<int>);
      } else {
        Directory(filename).createSync(recursive: true);
      }
    }
    return archiveFirstName.split('/').first;
  } catch (e) {
    throw Exception('Decompression failed: $e');
  }
}

String _getFileName(String path) {
  return path.split(Platform.pathSeparator).last;
}

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

Future<List<MDNSServer>> startMdnsServer(int port) async {
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
  List<MDNSServer> listMdnsServer = [];
  for (final ip in localIPs) {
    final instanceName = 'Dart Http Server [${ip.address}]';
    try {
      final service = await MDNSService.create(
        instance: instanceName,
        service: '_http._tcp',
        port: port,
        ips: [ip],
        txt: ['jsonrpc=/jsonrpc', 'interface=${ip.address}'],
      );
      final mDnsServer = MDNSServer(MDNSServerConfig(zone: service));
      await mDnsServer.start();
      listMdnsServer.add(mDnsServer);
      print('📌 mDNS Service: $instanceName bound to IP: ${ip.address} (port: ${service.port})');
    } catch (e) {
      print('❌ Failed to create service for ${ip.address}: $e');
    }
  }
  print('✅ All mDNS servers started!');
  return listMdnsServer;
}

Future<List<String>> getLocalIpAddresses() async {
  final interfaces = await NetworkInterface.list();
  List<String> localIps = [];
  for (final interface in interfaces) {
    for (final addr in interface.addresses) {
      if (addr.type == InternetAddressType.IPv4) {
        localIps.add(addr.address);
      }
    }
  }
  return localIps;
}

Future<List<ServiceEntry>> mDnsClient() async {
  // print('\nDiscovering HTTP services...');
  final localIps = await getLocalIpAddresses();
  // print('Local IPs to exclude: ${localIps.join(', ')}\n');
  final results = await MDNSClient.discover('_http._tcp', timeout: Duration(seconds: 3));
  final filteredResults = results.where((service) {
    final serviceIp = service.addrV4?.address;
    return serviceIp == null || !localIps.contains(serviceIp);
  }).toList();
  if (filteredResults.isEmpty) {
    // print('No HTTP services found\n');
    return [];
  } else {
    // print('Found ${filteredResults.length} HTTP service(s):');
    // for (final service in filteredResults) {
    //   print('Service: ${service.name}');
    //   print('  Host: ${service.host}');
    //   print('  IPv4: ${service.addrV4?.address ?? 'none'}');
    //   print('  IPv6: ${service.addrV6?.address ?? 'none'}');
    //   print('  Port: ${service.port}');
    //   print('  Info: ${service.info}');
    //   if (service.infoFields.isNotEmpty) {
    //     print('  TXT: ${service.infoFields.join(', ')}');
    //   }
    //   print('');
    // }
    return filteredResults;
  }
}

Future<List<String>> funcListMdnsServer() async {
  try {
    final listMdnsServer = await mDnsClient();
    if (listMdnsServer.isEmpty) return [];
    return listMdnsServer.map((mDnsServer) {
      final serviceData = {
        'host': mDnsServer.host,
        'ipv4': mDnsServer.addrV4?.address ?? 'none',
        'port': mDnsServer.port,
        'name': mDnsServer.name,
      };
      return jsonEncode(serviceData);
    }).toList();
  } catch (e) {
    throw Exception('Failed to list mDNS Server: $e');
  }
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

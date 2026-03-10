import 'dart:io';
import 'package:ini/ini.dart';
import 'package:archive/archive_io.dart';

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
    final fileNames = fileList.map((path) => getFileName(path)).toList();
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
    final dirNames = dirList.map((path) => getFileName(path)).toList();
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

Future<List<String>> getRootDirectory() async {
  try {
    if (Platform.isWindows) {
      List<String> availableDrives = [];
      for (int i = 65; i <= 90; i++) {
        String driveLetter = String.fromCharCode(i);
        String path = '$driveLetter:${Platform.pathSeparator}';
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

String getFileName(String path) {
  return path.split(Platform.pathSeparator).last;
}

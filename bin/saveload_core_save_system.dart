import 'dart:io';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as path_lib;
import 'saveload_core_file_system.dart';

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
    final saveList = contentsString.map((path) => getFileName(path)).toList();
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
    final comment = _getComment(content);
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
      return getFileName(targetFolder);
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
      return getFileName(targetFile);
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

String _getComment(String path) {
  return path.contains('@') ? (path.split('@').last).split('.').first : '';
}

import 'package:path/path.dart' as p;

/// Coarse classification of a file based on its extension.
///
/// We use this to keep binary files out of the code editor:
///
/// - `text` — open in `_EditorPane` (CodeEditor).
/// - `image` / `audio` / `video` / `binary` — route to
///   `BinaryPreviewPane` instead. `AppState.openFile` does NOT
///   `readAsString` these kinds (which is what produced
///   `FileSystemException: Failed to decode data using encoding
///   'utf-8'` when the user clicked a JPG).
///
/// Detection is deliberately extension-only — sniffing magic bytes
/// from disk on every selection is more correct but adds a sync read
/// before the tab opens, which is visible latency on a click. False
/// positives (a `.txt` file containing binary garbage, or a
/// `no-extension` text file) are handled as a fallback in
/// `AppState.openFile`: when extension says "text" but the utf-8
/// decode throws, we treat it as `binary` and switch the tab to the
/// preview view instead of stuffing `Error reading file: ...` into
/// the editor body.
enum FileKind { text, image, audio, video, binary }

class FileKindDetector {
  // Lower-cased extensions including the leading dot. New entries:
  // common formats only — there's no reward for being exhaustive,
  // and false positives (a real source file we wrongly mark as
  // binary) lose the user the ability to view their own code.
  static const Set<String> _imageExt = {
    '.jpg',
    '.jpeg',
    '.png',
    '.gif',
    '.bmp',
    '.webp',
    '.ico',
    '.tiff',
    '.tif',
    '.heic',
    '.heif',
    '.avif',
  };

  static const Set<String> _audioExt = {
    '.mp3',
    '.wav',
    '.flac',
    '.m4a',
    '.ogg',
    '.opus',
    '.aac',
    '.wma',
    '.aiff',
    '.aif',
  };

  static const Set<String> _videoExt = {
    '.mp4',
    '.mov',
    '.mkv',
    '.webm',
    '.avi',
    '.wmv',
    '.m4v',
    '.flv',
    '.mpg',
    '.mpeg',
    '.3gp',
  };

  // Catch-all binary list: archives, executables, design files, fonts,
  // databases, etc. Important to keep these out of the editor — at
  // best the user sees garbage, at worst the editor stalls trying to
  // syntax-highlight a 200MB blob.
  static const Set<String> _binaryExt = {
    '.zip',
    '.rar',
    '.7z',
    '.tar',
    '.gz',
    '.bz2',
    '.xz',
    '.exe',
    '.dll',
    '.bin',
    '.so',
    '.dylib',
    '.app',
    '.pdf',
    '.psd',
    '.ai',
    '.fig',
    '.sketch',
    '.iso',
    '.dmg',
    '.deb',
    '.rpm',
    '.msi',
    '.appx',
    '.ttf',
    '.otf',
    '.woff',
    '.woff2',
    '.eot',
    '.db',
    '.sqlite',
    '.sqlite3',
    '.mdb',
    '.pyc',
    '.class',
    '.jar',
    '.war',
  };

  static FileKind detect(String path) {
    final ext = p.extension(path).toLowerCase();
    if (_imageExt.contains(ext)) return FileKind.image;
    if (_audioExt.contains(ext)) return FileKind.audio;
    if (_videoExt.contains(ext)) return FileKind.video;
    if (_binaryExt.contains(ext)) return FileKind.binary;
    return FileKind.text;
  }

  /// True for [FileKind.text] only — the editor's code-editing widget
  /// is the right surface. Everything else routes to a preview pane.
  static bool isText(String path) => detect(path) == FileKind.text;

  /// True when the file is rendered as a media preview (image, audio
  /// or video) rather than a "binary blob" generic card. Useful for
  /// the editor pane to pick the right preview widget without an
  /// outer switch.
  static bool isMediaPreview(String path) {
    final k = detect(path);
    return k == FileKind.image || k == FileKind.audio || k == FileKind.video;
  }
}

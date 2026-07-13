// Streams PCM samples into a growable WAV file and patches the RIFF/data header sizes on finalize.
import 'dart:io';
import 'dart:typed_data';

class WavSegmentWriter {
  WavSegmentWriter._({
    required this.path,
    required this.sampleRate,
    required this.channels,
    required this._file,
  });

  final String path;
  final int sampleRate;
  final int channels;
  final RandomAccessFile _file;
  int _pcmBytes = 0;
  bool _closed = false;

  int get pcmBytes => _pcmBytes;

  int get sampleCount {
    final frameSize = channels * 2;
    if (frameSize <= 0) {
      return 0;
    }
    return _pcmBytes ~/ frameSize;
  }

  static Future<WavSegmentWriter> open({
    required String path,
    required int sampleRate,
    required int channels,
  }) async {
    final tempFile = File('$path.part');
    if (!await tempFile.parent.exists()) {
      await tempFile.parent.create(recursive: true);
    }
    final file = await tempFile.open(mode: FileMode.write);
    await file.writeFrom(Uint8List(44));
    return WavSegmentWriter._(
      path: path,
      sampleRate: sampleRate,
      channels: channels,
      file: file,
    );
  }

  Future<void> write(Uint8List bytes) async {
    if (_closed || bytes.isEmpty) {
      return;
    }
    await _file.writeFrom(bytes);
    _pcmBytes += bytes.length;
  }

  Future<File> close() async {
    if (_closed) {
      return File(path);
    }
    _closed = true;
    await _file.setPosition(0);
    await _file.writeFrom(_header());
    await _file.flush();
    await _file.close();
    final tempFile = File('$path.part');
    return tempFile.rename(path);
  }

  Future<void> cancel() async {
    if (!_closed) {
      _closed = true;
      await _file.close();
    }
    final tempFile = File('$path.part');
    if (await tempFile.exists()) {
      await tempFile.delete();
    }
  }

  Uint8List _header() {
    final byteRate = sampleRate * channels * 2;
    final blockAlign = channels * 2;
    final dataSize = _pcmBytes;
    final riffSize = 36 + dataSize;
    final data = ByteData(44);
    _writeAscii(data, 0, 'RIFF');
    data.setUint32(4, riffSize, Endian.little);
    _writeAscii(data, 8, 'WAVE');
    _writeAscii(data, 12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little);
    data.setUint16(22, channels, Endian.little);
    data.setUint32(24, sampleRate, Endian.little);
    data.setUint32(28, byteRate, Endian.little);
    data.setUint16(32, blockAlign, Endian.little);
    data.setUint16(34, 16, Endian.little);
    _writeAscii(data, 36, 'data');
    data.setUint32(40, dataSize, Endian.little);
    return data.buffer.asUint8List();
  }

  void _writeAscii(ByteData data, int offset, String value) {
    for (var i = 0; i < value.length; i += 1) {
      data.setUint8(offset + i, value.codeUnitAt(i));
    }
  }
}

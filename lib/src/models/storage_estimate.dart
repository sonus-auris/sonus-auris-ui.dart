// Computes device/cloud storage footprint from bitrate and retention hours, with a human-readable byte formatter.
class StorageEstimate {
  const StorageEstimate({
    required this.bitRate,
    required this.deviceHours,
    required this.cloudHours,
  });

  final int bitRate;
  final int deviceHours;
  final int cloudHours;

  int get bytesPerSecond => bitRate ~/ 8;

  int get bytesPerHour => bytesPerSecond * 3600;

  int get deviceBytes => bytesPerHour * deviceHours;

  int get cloudBytes => bytesPerHour * cloudHours;

  int get bytesPerMinute => bytesPerSecond * 60;

  static String formatBytes(num bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unitIndex = 0;
    while (value >= 1000 && unitIndex < units.length - 1) {
      value /= 1000;
      unitIndex++;
    }
    return '${value.toStringAsFixed(value >= 10 || unitIndex == 0 ? 0 : 1)} ${units[unitIndex]}';
  }

  static String formatDurationHours(num hours) {
    if (hours >= 24) {
      final days = hours / 24;
      return '${days.toStringAsFixed(days >= 10 ? 0 : 1)} days';
    }
    return '${hours.toStringAsFixed(hours >= 10 ? 0 : 1)} hours';
  }
}

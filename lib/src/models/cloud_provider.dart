// Enum of supported user-owned cloud destinations (S3, Google Drive, OneDrive, iCloud) with display labels and backend routing.
enum CloudProvider {
  s3,
  googleDrive,
  oneDrive,
  iCloudDrive;

  String get label {
    switch (this) {
      case CloudProvider.s3:
        return 'Amazon S3 / Cloudflare R2';
      case CloudProvider.googleDrive:
        return 'Google Drive';
      case CloudProvider.oneDrive:
        return 'Microsoft OneDrive';
      case CloudProvider.iCloudDrive:
        return 'Apple iCloud Drive';
    }
  }

  bool get requiresBackend => this != CloudProvider.s3;

  bool get isImplemented => true;

  static CloudProvider fromName(String? name) {
    return CloudProvider.values.firstWhere(
      (provider) => provider.name == name,
      orElse: () => CloudProvider.s3,
    );
  }
}

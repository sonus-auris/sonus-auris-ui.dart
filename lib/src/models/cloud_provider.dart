// Supported user-owned cloud destinations with display labels and backend routing.
enum CloudProvider {
  s3,
  googleDrive,
  oneDrive,
  iCloudDrive,
  dropbox;

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
      case CloudProvider.dropbox:
        return 'Dropbox';
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

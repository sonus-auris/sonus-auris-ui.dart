// Opt-in reverse-geocoder turning coordinates into a short place name for Day-of-My-Life notes.
import 'package:geocoding/geocoding.dart';

/// Reverse-geocodes coordinates to a short place name ("Santa Cruz") for the
/// "Drive" notes in a Day of My Life.
///
/// Privacy note: this calls the **platform** geocoder, which on most platforms
/// resolves over the network — so coordinates leave the device for this lookup.
/// It is therefore strictly opt-in (see `AppConfig.placeNamesEnabled`) and
/// fails soft, returning null on any error so a missing name never breaks the
/// archive.
class PlaceResolver {
  const PlaceResolver();

  Future<String?> describe(double latitude, double longitude) async {
    try {
      final marks = await placemarkFromCoordinates(latitude, longitude);
      if (marks.isEmpty) {
        return null;
      }
      final p = marks.first;
      for (final candidate in [p.locality, p.subLocality, p.name]) {
        final value = candidate?.trim();
        if (value != null && value.isNotEmpty) {
          return value;
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}

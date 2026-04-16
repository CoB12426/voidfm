import 'dart:typed_data';

class TrackInfo {
  final String title;
  final String artist;
  final String? album;
  final Uint8List? albumArt;

  const TrackInfo({
    required this.title,
    required this.artist,
    this.album,
    this.albumArt,
  });

  Map<String, dynamic> toJson() => {
        'title': title,
        'artist': artist,
        if (album != null) 'album': album,
      };

  @override
  bool operator ==(Object other) =>
      other is TrackInfo &&
      other.title == title &&
      other.artist == artist;

  @override
  int get hashCode => Object.hash(title, artist);

  @override
  String toString() => '$artist - $title';
}

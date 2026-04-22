/// Host-scoped defaults for coding CLI launches.
class HostCliLaunchPreferences {
  /// Creates a new [HostCliLaunchPreferences].
  const HostCliLaunchPreferences({this.startInYoloMode = false});

  /// Decodes [HostCliLaunchPreferences] from JSON.
  factory HostCliLaunchPreferences.fromJson(Map<String, dynamic> json) =>
      HostCliLaunchPreferences(
        startInYoloMode: json['startInYoloMode'] == true,
      );

  /// Whether supported coding CLIs should launch in YOLO mode for this host.
  final bool startInYoloMode;

  /// Whether this preferences record has no saved overrides.
  bool get isEmpty => !startInYoloMode;

  /// Encodes this preferences record as JSON.
  Map<String, dynamic> toJson() => {
    if (startInYoloMode) 'startInYoloMode': true,
  };

  /// Returns a copy of this record with selected fields replaced.
  HostCliLaunchPreferences copyWith({bool? startInYoloMode}) =>
      HostCliLaunchPreferences(
        startInYoloMode: startInYoloMode ?? this.startInYoloMode,
      );
}

# Repository notes for agents

- Use JDK 17 for Android/Gradle builds in this repo. JDK 25 fails in the Android/Kotlin toolchain with `IllegalArgumentException: 25.0.1`.
- On macOS, set `JAVA_HOME="$(/usr/libexec/java_home -v 17)"` before running `flutter build ...` or `./gradlew ...` for Android.

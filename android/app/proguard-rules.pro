# ProGuard / R8 keep rules for feiniumusic release builds.
# Flutter and most plugins ship their own consumer rules; these cover the
# libraries in this app that rely on reflection or are otherwise stripped.

# --- Flutter engine ---
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.embedding.** { *; }
-dontwarn io.flutter.**

# --- flutter_local_notifications (uses Gson + reflection for scheduled data) ---
-keep class com.dexterous.** { *; }
-keep class com.google.gson.** { *; }
-keep class * extends com.google.gson.TypeAdapter
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes InnerClasses
-keepattributes EnclosingMethod
# Keep generic signature of TypeToken & subclasses used by Gson
-keep,allowobfuscation class com.google.gson.reflect.TypeToken
-keep class * extends com.google.gson.reflect.TypeToken

# --- just_audio / audio_service / ExoPlayer (media3) ---
-keep class com.ryanheise.** { *; }
-keep class androidx.media3.** { *; }
-keep class androidx.media.** { *; }
-dontwarn androidx.media3.**

# --- sqflite ---
-keep class com.tekartik.** { *; }

# --- lyricon provider (io.github.proify.lyricon) ---
-keep class io.github.proify.** { *; }

# --- Kotlin coroutines / metadata ---
-keepclassmembers class kotlinx.coroutines.** { volatile <fields>; }
-dontwarn kotlinx.coroutines.**
-keep class kotlin.Metadata { *; }

# --- Keep enum values() / valueOf() used reflectively ---
-keepclassmembers enum * {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}

# --- Keep native method names ---
-keepclasseswithmembernames class * {
    native <methods>;
}

# --- Parcelable / Serializable ---
-keepclassmembers class * implements android.os.Parcelable {
    public static final ** CREATOR;
}
-keepnames class * implements java.io.Serializable
-keepclassmembers class * implements java.io.Serializable {
    static final long serialVersionUID;
    private static final java.io.ObjectStreamField[] serialPersistentFields;
    private void writeObject(java.io.ObjectOutputStream);
    private void readObject(java.io.ObjectInputStream);
    java.lang.Object writeReplace();
    java.lang.Object readResolve();
}

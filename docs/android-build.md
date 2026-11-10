# Android build stack

AGP 9.3 / Gradle 9.5 with **AGP's built-in Kotlin** — deliberately no `org.jetbrains.kotlin.android`
plugin (AGP 9's new DSL is incompatible with it). Before editing `CompanionApps/Android/*.gradle.kts`:

- Kotlin options go in a top-level `kotlin { compilerOptions { … } }` block. The old
  `android { kotlinOptions { … } }` form is deprecated-as-error under Kotlin 2.4.
- `gradle.properties` carries only `android.useAndroidX=true`. The AGP 9 upgrade needs none of the
  `android.newDsl` / `android.builtInKotlin` / `android.r8.*` opt-out shims — fix the underlying
  incompatibility instead; they all disappear in AGP 10.
- `protobuf-gradle-plugin` must be ≥ 0.10.0; earlier versions cast to the removed `BaseExtension`
  and fail under the new DSL.

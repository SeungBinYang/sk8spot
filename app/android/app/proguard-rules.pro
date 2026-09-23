# Kakao Map SDK는 코드 축소/난독화 대상에서 제외해야 한다 (플러그인 README).
# 빠뜨리면 release 빌드에서만 죽는다.
-keep class com.kakao.vectormap.** { *; }
-keep interface com.kakao.vectormap.**

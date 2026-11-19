# 播放验收样片

`playback.mp4` 是程序生成的 60 秒 H.264 色彩测试图，不包含用户媒体或原 IPA 资源。

```sh
ffmpeg -f lavfi -i testsrc2=size=320x180:rate=12 -t 60 -c:v libx264 -crf 28 -pix_fmt yuv420p -an -movflags +faststart playback.mp4
```

仅在 CI 停止模拟器应用后写入该模拟器的沙箱，用于真实解码、暂停和进度保存测试，不打包进应用。

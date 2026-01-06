# Runcore

Open `apple/App/iOS/Runcore.xcodeproj` in Xcode and run on a simulator/device.

Build the Go xcframework first:

```bash
./apple/Frameworks/build.sh ios
```

Then open the Xcode project and run. It links against `apple/Frameworks/iOS/Runcore.xcframework`.

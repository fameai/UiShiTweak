# UiShi

A jailbreak tweak that dynamically injects libHandleURLScheme.dylib and its dependencies (XCTest, Swift runtime) into target iOS applications.

## Features

- Dynamic injection of Swift-based libraries into iOS apps
- Automatic handling of XCTest framework dependencies
- Swift runtime library management
- Robust error handling and logging
- Debug mode support

## Requirements

- iOS 13.0 or later
- A jailbroken device
- Theos installed and configured
- Mobile Substrate or Substitute

## Installation

1. Clone the repository:
```bash
git clone https://github.com/yourusername/UiShi.git
cd UiShi
```

2. Place your compiled libHandleURLScheme.dylib in the `libs/` directory.

3. Run the library path fixing script:
```bash
./fix_libs.sh
```

4. Build and install:
```bash
make package install
```

## Configuration

### Debug Mode
To enable debug mode with additional logging:
```bash
make package install DEBUG=1
```

### Target Applications
Edit `UiShi.plist` to specify which apps to inject into. Default is Instagram:
```xml
<key>Bundles</key>
<array>
    <string>com.burbn.instagram</string>
</array>
```

## Project Structure

```
UiShi/
├── Makefile              # Build configuration
├── Tweak.x              # Main hooking code
├── UiShi.plist    # Target app filter
├── control              # Package metadata
├── fix_libs.sh          # Library path fixer
├── DEBIAN/
│   └── postinst         # Post-installation script
├── layout/
│   └── Library/
│       ├── Frameworks/  # XCTest and dependencies
│       └── MobileSubstrate/
└── libs/                # Your dylib goes here
```

## Troubleshooting

### Common Issues

1. **Library Loading Failures**
   - Check device logs for "[UiShi]" prefix
   - Verify all frameworks are in /Library/Frameworks
   - Ensure Swift runtime libraries are properly linked

2. **Missing Dependencies**
   - Run `otool -L libs/libHandleURLScheme.dylib` to verify paths
   - Check if all required frameworks are present

3. **Injection Issues**
   - Verify target bundle ID in UiShi.plist
   - Check MobileSubstrate logs
   - Ensure proper entitlements if needed

## Development

### Adding New Targets
1. Edit `UiShi.plist`
2. Add bundle IDs to the Bundles array
3. Respring device

### Debugging
Enable debug mode in Makefile:
```makefile
DEBUG=1
```

## License

[Your License Here]

## Credits

- [Your Name/Team]
- XCTest Framework by Apple
- Theos by DHowett and team 
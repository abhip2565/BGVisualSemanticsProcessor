# SemanticExplorer - iOS Demo App Setup

The **SemanticExplorer** Xcode project has been automatically generated using `xcodegen`.

## How to Run

1.  **Open the Project**:
    *   Open `DemoApps/SemanticExplorer/SemanticExplorer.xcodeproj` in Xcode.

2.  **Run**:
    *   Select the **SemanticExplorer** scheme.
    *   Select an **iPhone 16** or **iPad** simulator (iOS 16.0+).
    *   Press **Cmd + R** to build and run.

## Project Details

- **Architecture**: Native iOS SwiftUI App.
- **Dependency**: Links to the local `BGVisualSemanticsProcessor` and `BGVisualSemanticsProcessorVision` targets.
- **Permissions**: Pre-configured with `NSCameraUsageDescription`, `NSPhotoLibraryUsageDescription`, and `UIBackgroundModes`.
- **Aesthetic**: Industrial Utilitarian (Monospaced typography, technical status badges).

## Maintenance (Developers Only)

If you add new files to the source directory, you can regenerate the project file by running:
```bash
cd DemoApps/SemanticExplorer
xcodegen generate
```
This requires `xcodegen` to be installed (`brew install xcodegen`).

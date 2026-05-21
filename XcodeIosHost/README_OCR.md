# Third-party OCR (Google ML Kit)

## Fix build errors (`FBLPromises not found`, linker failed)

This error almost always means Xcode is **not** building the CocoaPods project, so `FBLPromises.framework` is never compiled.

**Open the workspace** (double-click `OpenInXcode.command` or `CardRecognitionApp.xcworkspace`):

| Avoid (old habit) | Use |
|-------------------|-----|
| `CardRecognitionApp.xcodeproj` alone | **`CardRecognitionApp.xcworkspace`** |

The app target now depends on the **Pods** subproject so either file can work after `pod install`, but the **workspace** is still the supported entry point.

In the Project navigator you should see **Pods** under the project (with `Pods.xcodeproj`). Under **Products** you should see `FBLPromises.framework` and `Pods_CardRecognitionApp.framework`.

1. **Quit Xcode**
2. Double-click **`XcodeIosHost/CardRecognitionApp.xcworkspace`** (or File → Open and pick the `.xcworkspace`)
3. Toolbar: select your **physical iPhone** (**not** Simulator — ML Kit does not link on Apple Silicon simulator)
4. **Product → Clean Build Folder** (⇧⌘K)
5. **Product → Build** (⌘B)

If it still fails:

```bash
cd XcodeIosHost
pod install
```

Then delete Derived Data: Xcode → Settings → Locations → Derived Data → arrow → delete `CardRecognitionApp-*` folder.

## One-time setup

```bash
cd XcodeIosHost
pod install
```

Open **`CardRecognitionApp.xcworkspace`**.

## Verify ML Kit on device

Console filter: `SlotRecognition`

```text
mlkit_slot='7♥' backend=MLKit
```

On simulator you will see `backend=Vision` only (expected).

# PS5Upload

## Updates

The app checks GitHub for new versions, but it can't replace itself inside the sandbox. New versions come through `flatpak update`, usually within a few hours of an upstream release.

## DualSense

The `.deb` and `.rpm` install a udev rule that lets you open a DualSense's touchpad, motion sensors and adaptive triggers. A Flatpak can't install udev rules. If the app can't open the controller, save this as `/etc/udev/rules.d/70-ps5upload-dualsense.rules` and replug the controller:

```
KERNEL=="hidraw*", ATTRS{idVendor}=="054c", ATTRS{idProduct}=="0ce6", MODE="0660", TAG+="uaccess"
KERNEL=="hidraw*", ATTRS{idVendor}=="054c", ATTRS{idProduct}=="0df2", MODE="0660", TAG+="uaccess"
KERNEL=="hidraw*", KERNELS=="*054C:0CE6*", MODE="0660", TAG+="uaccess"
KERNEL=="hidraw*", KERNELS=="*054C:0DF2*", MODE="0660", TAG+="uaccess"
```

Steam's `steam-devices` package covers the same controllers.

## Keeping the PC awake

Upstream keeps the PC awake during transfers through `systemd-inhibit`, which isn't in the sandbox, so that option does nothing here.

## Graphics

This build turns on WebKit's DMA-BUF renderer, which upstream turns off on everything but recent NVIDIA drivers. Without it, Remote Play drops to a few frames per second. If the window stays white or blank, turn it off again:

```
flatpak override --user --env=WEBKIT_DISABLE_DMABUF_RENDERER=1 com.phantomptr.ps5upload
```

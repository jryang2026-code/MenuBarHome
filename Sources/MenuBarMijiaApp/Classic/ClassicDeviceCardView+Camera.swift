import SwiftUI
import MijiaCore

extension ClassicDeviceCardView {
    // MARK: - 9. Smart Camera Controls & Live View Popout (#97)

    func cameraDrawer(_ spec: CameraSpec) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ScrollView(.horizontal, showsIndicators: false) {
                AdaptiveGlassContainer(spacing: 6) {
                    HStack(spacing: 6) {
                        Button {
                            if spec.powerWritable, !spec.isOn {
                                _ = store.togglePrimary(device)
                            }
                            store.openCameraLiveView(device.id)
                        } label: {
                            Label(L10n.tr("放大实时画面", "Open Live View"), systemImage: "pip.enter")
                        }
                        .buttonStyle(ClassicPillActionButtonStyle(isSelected: true, tintColor: accent))
                        .disabled(!device.isOnline)

                        if spec.powerWritable {
                            Button {
                                _ = store.togglePrimary(device)
                                if device.isOnline { SoundFeedback.playSuccess() }
                            } label: {
                                Label(
                                    spec.isOn ? L10n.tr("镜头休眠", "Sleep") : L10n.tr("唤醒镜头", "Wake"),
                                    systemImage: spec.isOn ? "moon.zzz.fill" : "video.fill"
                                )
                            }
                            .buttonStyle(ClassicPillActionButtonStyle(isSelected: !spec.isOn, tintColor: accent))
                            .disabled(!device.isOnline)
                        }

                        if spec.motionDetectionEntityId != nil {
                            let motionOn = spec.isMotionDetectionOn ?? false
                            Button {
                                store.setCameraMotionDetection(device.id, enabled: !motionOn)
                            } label: {
                                Label(
                                    motionOn ? L10n.tr("移动侦测：开", "Motion: On") : L10n.tr("移动侦测：关", "Motion: Off"),
                                    systemImage: "figure.walk.motion"
                                )
                            }
                            .buttonStyle(ClassicPillActionButtonStyle(isSelected: motionOn, tintColor: accent))
                            .disabled(!device.isOnline)
                        }
                    }
                }
                .padding(6)
            }
            .padding(-6)

            if !spec.availableNightShots.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    AdaptiveGlassContainer(spacing: 6) {
                        HStack(spacing: 6) {
                            ForEach(spec.availableNightShots, id: \.self) { mode in
                                let selected = (spec.nightShot == mode)
                                Button(SmartDevice.localizeNightShot(mode)) {
                                    store.setCameraNightShot(device.id, mode: mode)
                                }
                                .buttonStyle(ClassicPillActionButtonStyle(isSelected: selected, tintColor: accent))
                                .disabled(!device.isOnline)
                            }
                        }
                    }
                    .padding(6)
                }
                .padding(-6)
            }
        }
    }
}

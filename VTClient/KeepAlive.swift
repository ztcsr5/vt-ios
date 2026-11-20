//
//  KeepAlive.swift
//  靠"播放静音音频"把 App 留在后台。
//
//  为什么是这个办法：iOS 上真正的不掉线需要 NetworkExtension（付费开发者账号），
//  这里没有账号，所以退一步用音频后台模式。系统规则允许"正在输出的音频 App"在后台
//  继续运行；我们用 AVAudioEngine 的程序化源节点持续输出 0 样本，
//  不占存储、不发出声音、CPU 占用极低。
//
//  限制（实话）：省电模式 / 长时间无交互 / 低电量时系统仍可能挂起；
//  这不是 100% 不掉线，但比什么都不做强得多。
//

import Foundation
import AVFoundation

final class KeepAlive {

    private var engine: AVAudioEngine?
    private var src: AVAudioSourceNode?
    private(set) var active = false
    var onLog: ((String) -> Void)?

    func start() {
        guard !active else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            // .mixWithOthers 避免打断用户正在听的音乐
            try session.setCategory(.playback, mode: .default,
                                    options: [.mixWithOthers, .allowBluetoothA2DP])
            try session.setActive(true)

            let eng = AVAudioEngine()
            let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!

            // 输出全 0：数据静音，但音频管线真实在跑
            let node = AVAudioSourceNode(format: fmt) { _, _, frameCount, audioBufferList -> OSStatus in
                let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
                for buf in abl {
                    memset(buf.mData, 0, Int(buf.mDataByteSize))
                }
                _ = frameCount
                return noErr
            }
            eng.attach(node)
            eng.connect(node, to: eng.mainMixerNode, format: fmt)
            eng.mainMixerNode.outputVolume = 0.0
            try eng.start()

            engine = eng
            src = node
            active = true
            onLog?("后台保活已启动（静音音频）")
        } catch {
            active = false
            onLog?("保活启动失败: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard active else { return }
        engine?.stop()
        if let s = src { engine?.detach(s) }
        engine = nil
        src = nil
        try? AVAudioSession.sharedInstance().setActive(false,
                                                       options: [.notifyOthersOnDeactivation])
        active = false
        onLog?("后台保活已停止")
    }
}

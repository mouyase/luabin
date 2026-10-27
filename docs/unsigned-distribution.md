# 不签名的代价

Windows 和 macOS 都没买签名证书。这是权衡后的选择，代价得说清楚。

## macOS 比 Windows 严格

**浏览器下载的 `.pkg` 打不开。** 会带上 `com.apple.quarantine` 扩展属性，双击被 Gatekeeper 直接拒绝。它不弹警告让你确认，窗口一闪就没了。

**curl 下载不带这个标记。** 实测过，`xattr` 输出是空的。

```
$ xattr qt.tar.gz
$ echo $?
0
```

而浏览器下载的文件会带一行。

```
com.apple.quarantine: 0183;6adec7e7;Free Download Manager;699E7D36-...
```

这个差异是 `install.sh` 存在的核心原因。走脚本安装完全不受 Gatekeeper 影响，因为 `curl` 下载的文件没有隔离标记。

所以 README 和 Release 说明都把脚本列为首选路径，`.pkg` 标成备用方案。

**实在要用 `.pkg`**，手动去掉标记就行。

```sh
xattr -d com.apple.quarantine ~/Downloads/lua-5.5.1-macos-arm64.pkg
```

然后双击就能装。

**Windows 宽松一些。** 未签名的 `.exe` 触发 SmartScreen 的“Windows 已保护你的电脑”，点“更多信息”再点“仍要运行”就过去了。属于警告，不拦你。`.zip` 完全没有提示。

## 正经分发需要什么

**macOS** 需要 Apple Developer Program，每年 99 美元。流程分三步。

用 Developer ID 证书签名（`codesign --options runtime`），提交公证（`notarytool submit`），通过后装订票据（`stapler staple`）。这套流程 CI 里能跑，但证书和 Apple ID 得进 secrets。

公证要等，通常几分钟到几十分钟，会拖长流水线。

**Windows** 更麻烦。2023 年 6 月起，代码签名证书必须存在硬件令牌或云 HSM 里，不能再拿一个 `.pfx` 文件塞进 CI 了。

现在的选项是 Azure Trusted Signing，约 10 美元每月，或者买 EV 证书配云 HSM，一次性几百美元加年费。前者门槛低些，但需要企业资质审核。

## 现状

两个都不在预算内，所以就这样发。

实际影响可控。macOS 用户走脚本，Windows 用户点两下就能装。难受的是给不熟悉这些的用户分发，他们看到系统警告会以为文件有毒。

如果哪天要正经分发，这份文档就是当时的起点。

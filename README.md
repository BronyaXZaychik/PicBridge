# PicBridge · 图桥

把电脑里的图片，用手机浏览器看。
不用插线、不用传文件、不用装 App，同一 Wi-Fi 扫码即看。

## 下载

| 版本 | 大小 | 适用 | 下载 |
|---|---|---|---|
| 标准版 | 20 MB | 大多数人（webp/png/jpg/gif） | [Standard.Edition.zip](https://github.com/BronyaXZaychik/PicBridge/releases/download/V.1.0/Standard.Edition.zip) |
| 增强版 | 41 MB | 有 iPhone 照片 / 扫描件 / AVIF | [Enhanced.version.zip](https://github.com/BronyaXZaychik/PicBridge/releases/download/V.1.0/Enhanced.version.zip) |

解压后双击 `1-创建桌面快捷方式.bat`，再从桌面图标启动。
首次启动会让你选一个图片文件夹，之后手机扫码即可。

## 特点

- 动图 WebP 自动生成轻量版，手机播放不卡（体积约为原图 1/50）
- 支持多文件夹同时挂载，改目录热生效，不用重启
- 内置二维码，纯 Python 生成，离线可用
- 四种界面：简洁 / 标准 / 详细 / 自定义，可调透明度
- 照片 EXIF 方向自动修正
- **只读**：不修改、不重命名、不删除任何原图
- 不写注册表、不装服务、不开机自启

## 增强版额外支持

`heic` `heif`（iPhone）、`tif` `tiff`（扫描件）、`bmp` `ico`、`avif`

其中 HEIC/AVIF/TIFF 可自动转成 JPG，兼容各类浏览器，转换结果缓存在 `程序\缓存\conv`。

## 从源码运行

```bash
pip install pillow
python serve.py "D:\你的图片文件夹" --port 8765

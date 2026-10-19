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
```

## 碎碎念

这玩意儿为什么会诞生出来呢，就是机长在用 E 站的时候，每次看见 AI 动图都太大，加上魔法太慢，总是很不爽。下载到电脑上之后还要传到手机，又觉得巨浪费时间；最主要是折腾半天，手机怎么都看不了 webp 图。于是就配合大肥鱼整出这么个东西。（涩涩才是人类进步的原动力啊！）

一开始其实就是个简单的转动图工具，输入网址看就好了。但琢磨了半天，发现每次打开也挺麻烦，而且怕图片堆着占空间，于是一点点变成现在这样。

如果有人用的话，可以给我留言，说说哪里有问题、或者需要什么新功能。

补一句：这个目前测试只能在自己家局域网内用。不过一般情况下大家都是在家用吧，公司那种地方就不知道能不能用了。

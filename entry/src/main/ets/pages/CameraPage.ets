import router from '@ohos.router';
import camera from '@ohos.multimedia.camera';
import image from '@ohos.multimedia.image';
import fs from '@ohos.file.fs';
import { BusinessError } from '@ohos.base';

@Entry
@Component
struct CameraPage {
  @State surfaceId: string = '';
  @State isCapturing: boolean = false;
  @State message: string = '';
  private xComponentController: XComponentController = new XComponentController();
  private cameraManager: camera.CameraManager | null = null;
  private captureSession: camera.CaptureSession | null = null;
  private photoOutput: camera.PhotoOutput | null = null;
  private cameras: camera.CameraDevice[] = [];

  aboutToDisappear() {
    this.releaseCamera();
  }

  async initCamera() {
    try {
      // 获取相机管理器
      this.cameraManager = camera.getCameraManager(getContext(this));

      // 获取相机列表
      this.cameras = this.cameraManager.getSupportedCameras();
      if (this.cameras.length === 0) {
        this.message = '未检测到相机';
        return;
      }

      // 使用后置摄像头
      const cameraDevice = this.cameras[0];

      // 创建捕获会话
      this.captureSession = this.cameraManager.createCaptureSession();
      this.captureSession.beginConfig();

      // 相机输入
      const cameraInput = this.cameraManager.createCameraInput(cameraDevice);
      await cameraInput.open();
      this.captureSession.addInput(cameraInput);

      // 预览输出
      const previewProfiles = this.cameraManager.getSupportedOutputCapability(cameraDevice).previewProfiles;
      const previewProfile = previewProfiles[0];
      const surfaceId = this.xComponentController.getXComponentSurfaceId();
      const previewOutput = this.cameraManager.createPreviewOutput(previewProfile, surfaceId);
      this.captureSession.addOutput(previewOutput);

      // 拍照输出
      const photoProfiles = this.cameraManager.getSupportedOutputCapability(cameraDevice).photoProfiles;
      const photoProfile = photoProfiles[0];
      const imageReceiver = image.createImageReceiver(photoProfile.size.width, photoProfile.size.height,
        image.ImageFormat.JPEG, 8);
      const photoSurfaceId = await imageReceiver.getReceivingSurfaceId();
      this.photoOutput = this.cameraManager.createPhotoOutput(photoProfile, photoSurfaceId);
      this.captureSession.addOutput(this.photoOutput);

      // 提交配置并启动
      await this.captureSession.commitConfig();
      await this.captureSession.start();

      // 设置拍照回调
      imageReceiver.on('imageArrival', async () => {
        try {
          const img = await imageReceiver.readNextImage();
          const imgComponent = await img.getComponent(image.ComponentType.JPEG);
          const buffer = imgComponent.byteBuffer;

          // 保存到临时文件
          const tempPath = getContext(this).tempDir + `/capture_${Date.now()}.jpg`;
          const file = fs.openSync(tempPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
          fs.writeSync(file.fd, buffer);
          fs.closeSync(file);

          img.release();

          // 通过 AppStorage 传递图片路径给主页面
          AppStorage.setOrCreate('capturedImagePath', tempPath);
          router.back();
        } catch (err) {
          console.error('保存照片失败:', err);
          this.isCapturing = false;
          this.message = '保存照片失败';
        }
      });

      this.message = '';
    } catch (err) {
      const error = err as BusinessError;
      console.error('相机初始化失败:', error.message);
      this.message = `相机初始化失败: ${error.message}`;
    }
  }

  async handleCapture() {
    if (this.isCapturing || !this.photoOutput) {
      return;
    }
    this.isCapturing = true;
    try {
      await this.photoOutput.capture();
    } catch (err) {
      console.error('拍照失败:', err);
      this.isCapturing = false;
      this.message = '拍照失败';
    }
  }

  releaseCamera() {
    try {
      if (this.captureSession) {
        this.captureSession.stop();
        this.captureSession.release();
        this.captureSession = null;
      }
      this.cameraManager = null;
    } catch (err) {
      console.error('释放相机失败:', err);
    }
  }

  build() {
    Column() {
      // 顶部栏
      Row() {
        Button('返回')
          .fontSize(12)
          .fontColor('#ffffff')
          .height(28)
          .padding({ left: 12, right: 12 })
          .backgroundColor('rgba(255, 255, 255, 0.2)')
          .borderRadius(14)
          .onClick(() => {
            this.releaseCamera();
            router.back();
          });
        Text('拍照检测')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#ffffff')
          .layoutWeight(1)
          .textAlign(TextAlign.Center);
        Row().width(56);
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .linearGradient({
        direction: GradientDirection.Right,
        colors: [['#2B6CB0', 0], ['#4299E1', 1]]
      });

      // 相机预览
      Stack() {
        XComponent({
          id: 'cameraPreview',
          type: 'surface',
          controller: this.xComponentController
        })
          .onLoad(() => {
            this.initCamera();
          })
          .width('100%')
          .height('100%');

        // 提示信息
        if (this.message) {
          Text(this.message)
            .fontSize(14)
            .fontColor('#e53e3e')
            .backgroundColor('rgba(255, 255, 255, 0.8)')
            .padding(8)
            .borderRadius(8);
        }

        // 对焦框提示
        if (!this.message) {
          Column() {
            Row()
              .width(200)
              .height(280)
              .borderWidth(2)
              .borderColor('rgba(255, 255, 255, 0.6)')
              .borderRadius(8);
            Text('请对准能效标签')
              .fontSize(13)
              .fontColor('rgba(255, 255, 255, 0.8)')
              .margin({ top: 12 });
          }
          .justifyContent(FlexAlign.Center);
        }
      }
      .layoutWeight(1)
      .backgroundColor('#000000');

      // 底部控制栏
      Row() {
        // 拍照按钮
        Column() {
          Stack() {
            Circle()
              .width(70)
              .height(70)
              .fill(Color.White)
              .opacity(0.3);
            Circle()
              .width(60)
              .height(60)
              .fill(Color.White);
            if (this.isCapturing) {
              LoadingProgress()
                .width(30)
                .height(30)
                .color('#000000');
            }
          }
        }
        .onClick(() => this.handleCapture());
      }
      .width('100%')
      .height(100)
      .justifyContent(FlexAlign.Center)
      .backgroundColor('#1a1a2e');
    }
    .height('100%')
    .width('100%')
    .backgroundColor('#000000');
  }
}

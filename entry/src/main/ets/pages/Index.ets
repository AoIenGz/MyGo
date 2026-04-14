import router from '@ohos.router';
import http from '@ohos.net.http';
import picker from '@ohos.file.picker';
import fs from '@ohos.file.fs';
import util from '@ohos.util';
import camera from '@ohos.multimedia.camera';
import image from '@ohos.multimedia.image';
import {
  DetectionResult, AnalyzeResult, Defects, Position,
  SystemStatus, DetectionMode, IndustrialCameraConfig,
  DetectionSessionStats, AutoDetectionRecord
} from '../common/Interfaces';
import { BusinessError } from '@ohos.base';

// 等级颜色映射
const GRADE_COLORS: Record<number, string> = {
  1: '#38a169',
  2: '#68d391',
  3: '#ecc94b',
  4: '#ed8936',
  5: '#e53e3e',
};

const GRADE_BG_COLORS: Record<number, string> = {
  1: '#c6f6d5',
  2: '#e6ffed',
  3: '#fefcbf',
  4: '#feebc8',
  5: '#fed7d7',
};

const GRADE_NAMES: Record<number, string> = {
  1: '1级',
  2: '2级',
  3: '3级',
  4: '4级',
  5: '5级',
};

// API 服务
class ApiService {
  private baseUrl: string = 'http://10.0.2.2:3000/api';

  async analyzeImage(base64Data: string): Promise<AnalyzeResult> {
    const httpRequest = http.createHttp();
    const response = await httpRequest.request(`${this.baseUrl}/detection/analyze`, {
      method: http.RequestMethod.POST,
      header: { 'Content-Type': 'application/json' },
      extraData: JSON.stringify({ image: base64Data }),
    });
    if (response.responseCode === 200) {
      return JSON.parse(response.result as string) as AnalyzeResult;
    } else {
      throw new Error(`HTTP error: ${response.responseCode}`);
    }
  }
}

const apiService = new ApiService();

@Entry
@Component
struct Index {
  // ===== 共享状态 =====
  @State currentMode: DetectionMode = 'manual';
  @State detectionResult: DetectionResult | null = null;
  @State errorMessage: string = '';
  @State systemStatus: SystemStatus = {
    cameraStatus: '就绪',
    detectionSpeed: '-',
    uptime: '-',
  };

  // ===== 手动模式状态 =====
  @State selectedImageUri: string = '';
  @State isAnalyzing: boolean = false;
  @State showTestPicker: boolean = false;

  // ===== 产线模式状态 =====
  @State isIndustrialRunning: boolean = false;
  @State isAnalyzingCurrent: boolean = false;
  @State sessionStats: DetectionSessionStats = {
    totalCaptures: 0,
    passCount: 0,
    failCount: 0,
    passRate: 0,
    averageTime: 0,
    sessionStart: 0,
    defectDamaged: 0,
    defectStained: 0,
    defectWrinkled: 0,
  };
  @State recentResults: AutoDetectionRecord[] = [];
  @State industrialConfig: IndustrialCameraConfig = {
    captureInterval: 10,
  };
  @State industrialMessage: string = '';
  @State sessionDuration: string = '00:00:00';

  // ===== 产线模式私有成员 =====
  private xComponentController: XComponentController = new XComponentController();
  private cameraManager: camera.CameraManager | null = null;
  private captureSession: camera.CaptureSession | null = null;
  private photoOutput: camera.PhotoOutput | null = null;
  private captureTimer: number = -1;
  private durationTimer: number = -1;
  private detectionCounter: number = 0;
  private totalTime: number = 0;

  // ===== 测试图片 =====
  private testImageGroups: TestImageGroup[] = [
    {
      title: '能效等级标签（正常）',
      images: [
        { name: '1级 (正常)', file: 'test_images/test_L1_nor.jpg', desc: '绿色标签' },
        { name: '2级 (正常)', file: 'test_images/test_L2_nor.jpg', desc: '浅绿标签' },
        { name: '3级 (正常)', file: 'test_images/test_L3_nor.jpg', desc: '黄色标签' },
        { name: '4级 (正常)', file: 'test_images/test_L4_nor.jpg', desc: '橙色标签' },
        { name: '5级 (正常)', file: 'test_images/test_L5_nor.jpg', desc: '红色标签' },
      ]
    },
    {
      title: '破损缺陷 (DAM)',
      images: [
        { name: '破损 #003', file: 'test_images/A02_L2_T01_DAM_003.jpg', desc: '标签破损' },
        { name: '破损 #015', file: 'test_images/A02_L2_T01_DAM_015.jpg', desc: '标签破损' },
      ]
    },
    {
      title: '污渍缺陷 (STA)',
      images: [
        { name: '污渍 #023', file: 'test_images/A02_L2_T04_STA_023.jpg', desc: '标签污渍' },
        { name: '污渍 #033', file: 'test_images/A02_L2_T04_STA_033.jpg', desc: '标签污渍' },
      ]
    },
    {
      title: '褶皱缺陷 (WRI)',
      images: [
        { name: '褶皱 #015', file: 'test_images/A02_L2_T06_WRI_015.jpg', desc: '标签褶皱' },
        { name: '褶皱 #035', file: 'test_images/A02_L2_T06_WRI_035.jpg', desc: '标签褶皱' },
      ]
    },
    {
      title: '位置偏移',
      images: [
        { name: '偏移样本 #022', file: 'test_images/A02_L2_T06_NOR_022.jpg', desc: '标签位置偏移' },
        { name: '偏移样本 #028', file: 'test_images/A02_L2_T06_NOR_028.jpg', desc: '标签位置偏移' },
      ]
    },
  ];

  // ===== 生命周期 =====
  aboutToDisappear() {
    this.stopIndustrialDetection();
  }

  // ===== 模式切换 =====
  handleModeSwitch(mode: DetectionMode) {
    if (this.currentMode === mode) return;
    if (this.currentMode === 'industrial') {
      this.stopIndustrialDetection();
    }
    this.currentMode = mode;
    this.detectionResult = null;
    this.errorMessage = '';
  }

  // ===== 手动模式方法 =====
  async handleSelectImage() {
    try {
      const photoSelectOptions = new picker.PhotoSelectOptions();
      photoSelectOptions.MIMEType = picker.PhotoViewMIMETypes.IMAGE_TYPE;
      photoSelectOptions.maxSelectNumber = 1;

      const photoViewPicker = new picker.PhotoViewPicker();
      const photoSelectResult = await photoViewPicker.select(photoSelectOptions);

      if (photoSelectResult.photoUris && photoSelectResult.photoUris.length > 0) {
        this.selectedImageUri = photoSelectResult.photoUris[0];
        this.errorMessage = '';
      }
    } catch (err) {
      const error = err as BusinessError;
      console.error('选择图片失败:', error.message);
      this.errorMessage = '选择图片失败';
    }
  }

  handleOpenCamera() {
    router.pushUrl({
      url: 'pages/CameraPage',
      params: { fromPage: 'Index' }
    });
  }

  handleLoadTestImage(fileName: string) {
    try {
      const context = getContext(this);
      const rawdata = context.resourceManager.getRawFileContentSync(fileName);
      const tempPath = context.tempDir + `/test_${Date.now()}.jpg`;
      const file = fs.openSync(tempPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
      const ab = rawdata.buffer.slice(rawdata.byteOffset, rawdata.byteOffset + rawdata.byteLength);
      fs.writeSync(file.fd, ab);
      fs.closeSync(file);
      this.selectedImageUri = 'file://' + tempPath;
      this.errorMessage = '';
      this.showTestPicker = false;
    } catch (err) {
      console.error('加载测试图片失败:', err);
      this.errorMessage = '加载测试图片失败';
    }
  }

  onPageShow() {
    const camPath = AppStorage.get<string>('capturedImagePath') || '';
    if (camPath) {
      this.selectedImageUri = camPath;
      this.errorMessage = '';
      AppStorage.setOrCreate('capturedImagePath', '');
    }
  }

  bufferToBase64(bytes: Uint8Array): string {
    const base64Helper = new util.Base64Helper();
    return base64Helper.encodeToStringSync(bytes);
  }

  async handleAnalyze() {
    if (!this.selectedImageUri) {
      this.errorMessage = '请先选择或拍摄图片';
      return;
    }

    this.isAnalyzing = true;
    this.errorMessage = '';
    this.detectionResult = null;
    const startTime = Date.now();

    try {
      const filePath = this.selectedImageUri.replace('file://', '');
      const file = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(filePath);
      const buffer = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buffer);
      fs.closeSync(file);

      const bytes = new Uint8Array(buffer);
      const base64Str = this.bufferToBase64(bytes);
      const ext = filePath.toLowerCase().endsWith('.png') ? 'png' : 'jpeg';
      const base64Data = `data:image/${ext};base64,${base64Str}`;

      const result = await apiService.analyzeImage(base64Data);
      this.detectionResult = this.convertResult(result);
    } catch (err) {
      const errMsg = err instanceof Object ? (err as BusinessError).message : String(err);
      this.errorMessage = `检测失败: ${errMsg}`;
      console.error('检测失败:', errMsg);
    } finally {
      const elapsed = Date.now() - startTime;
      this.systemStatus.detectionSpeed = `${elapsed}ms`;
      this.isAnalyzing = false;
    }
  }

  convertResult(raw: AnalyzeResult): DetectionResult {
    if (!raw.success) {
      this.errorMessage = raw.message || raw.error || '检测失败';
    }
    return {
      grade: raw.grade || 0,
      gradeMethod: raw.gradeMethod || '',
      gradeConfidence: raw.gradeConfidence || 0,
      energyParam: raw.energyParam != null ? `${raw.energyParam}` : '未识别',
      standbyPower: raw.standbyPower != null ? `${raw.standbyPower}W` : '未识别',
      isDataMatch: raw.labelFound,
      defects: raw.defects || { isDamaged: false, isStained: false, isWrinkled: false },
      position: raw.position || { isCorrect: true, x: 0, y: 0, deviation: 0 },
      isPass: raw.isPass,
      labelFound: raw.labelFound,
      hasDefect: raw.hasDefect || false,
    };
  }

  // ===== 产线模式方法 =====
  async initIndustrialCamera() {
    try {
      this.cameraManager = camera.getCameraManager(getContext(this));
      const cameras = this.cameraManager.getSupportedCameras();
      if (cameras.length === 0) {
        this.industrialMessage = '未检测到相机';
        return;
      }

      const cameraDevice = cameras[0];
      this.captureSession = this.cameraManager.createCaptureSession();
      this.captureSession.beginConfig();

      const cameraInput = this.cameraManager.createCameraInput(cameraDevice);
      await cameraInput.open();
      this.captureSession.addInput(cameraInput);

      const previewProfiles = this.cameraManager.getSupportedOutputCapability(cameraDevice).previewProfiles;
      const previewProfile = previewProfiles[0];
      const surfaceId = this.xComponentController.getXComponentSurfaceId();
      const previewOutput = this.cameraManager.createPreviewOutput(previewProfile, surfaceId);
      this.captureSession.addOutput(previewOutput);

      const photoProfiles = this.cameraManager.getSupportedOutputCapability(cameraDevice).photoProfiles;
      const photoProfile = photoProfiles[0];
      const imageReceiver = image.createImageReceiver(photoProfile.size.width, photoProfile.size.height,
        image.ImageFormat.JPEG, 8);
      const photoSurfaceId = await imageReceiver.getReceivingSurfaceId();
      this.photoOutput = this.cameraManager.createPhotoOutput(photoProfile, photoSurfaceId);
      this.captureSession.addOutput(this.photoOutput);

      await this.captureSession.commitConfig();
      await this.captureSession.start();

      imageReceiver.on('imageArrival', async () => {
        await this.handleAutoCaptureImage(imageReceiver);
      });

      this.industrialMessage = '';
    } catch (err) {
      const error = err as BusinessError;
      console.error('相机初始化失败:', error.message);
      this.industrialMessage = `相机初始化失败: ${error.message}`;
    }
  }

  async handleAutoCaptureImage(imageReceiver: image.ImageReceiver) {
    try {
      const img = await imageReceiver.readNextImage();
      const imgComponent = await img.getComponent(image.ComponentType.JPEG);
      const buffer = imgComponent.byteBuffer;

      const tempPath = getContext(this).tempDir + `/industrial_${Date.now()}.jpg`;
      const file = fs.openSync(tempPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
      fs.writeSync(file.fd, buffer);
      fs.closeSync(file);
      img.release();

      this.detectionCounter++;
      const record: AutoDetectionRecord = {
        id: this.detectionCounter,
        timestamp: this.formatTime(new Date()),
        imageUri: tempPath,
        result: null,
        status: 'captured',
        errorMessage: '',
      };
      this.recentResults.unshift(record);
      if (this.recentResults.length > 50) {
        this.recentResults.pop();
      }

      await this.autoAnalyze(tempPath, this.detectionCounter);
    } catch (err) {
      console.error('自动拍照处理失败:', err);
    }
  }

  async autoAnalyze(imagePath: string, recordId: number) {
    this.isAnalyzingCurrent = true;
    const startTime = Date.now();

    try {
      const file = fs.openSync(imagePath, fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(imagePath);
      const buffer = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buffer);
      fs.closeSync(file);

      const bytes = new Uint8Array(buffer);
      const base64Str = this.bufferToBase64(bytes);
      const base64Data = `data:image/jpeg;base64,${base64Str}`;

      const raw = await apiService.analyzeImage(base64Data);
      const result = this.convertResult(raw);

      // 更新对应记录
      for (let i = 0; i < this.recentResults.length; i++) {
        if (this.recentResults[i].id === recordId) {
          this.recentResults[i].result = result;
          this.recentResults[i].status = 'completed';
          break;
        }
      }

      // 更新会话统计
      const elapsed = Date.now() - startTime;
      this.totalTime += elapsed;
      this.sessionStats.totalCaptures++;
      if (result.isPass) {
        this.sessionStats.passCount++;
      } else {
        this.sessionStats.failCount++;
      }
      this.sessionStats.passRate = this.sessionStats.totalCaptures > 0
        ? Math.round(this.sessionStats.passCount / this.sessionStats.totalCaptures * 100) : 0;
      this.sessionStats.averageTime = Math.round(this.totalTime / this.sessionStats.totalCaptures);
      if (result.defects.isDamaged) this.sessionStats.defectDamaged++;
      if (result.defects.isStained) this.sessionStats.defectStained++;
      if (result.defects.isWrinkled) this.sessionStats.defectWrinkled++;

      // 更新共享的检测结果（显示在详情区域）
      this.detectionResult = result;
    } catch (err) {
      const errMsg = err instanceof Object ? (err as BusinessError).message : String(err);
      console.error('自动分析失败:', errMsg);
      for (let i = 0; i < this.recentResults.length; i++) {
        if (this.recentResults[i].id === recordId) {
          this.recentResults[i].status = 'failed';
          this.recentResults[i].errorMessage = errMsg;
          break;
        }
      }
    } finally {
      this.isAnalyzingCurrent = false;
      // 清理临时文件
      try { fs.unlinkSync(imagePath); } catch (e) { }
    }
  }

  async startIndustrialDetection() {
    this.sessionStats = {
      totalCaptures: 0, passCount: 0, failCount: 0, passRate: 0,
      averageTime: 0, sessionStart: Date.now(),
      defectDamaged: 0, defectStained: 0, defectWrinkled: 0,
    };
    this.recentResults = [];
    this.detectionCounter = 0;
    this.totalTime = 0;
    this.detectionResult = null;
    this.industrialMessage = '';

    await this.initIndustrialCamera();
    if (this.industrialMessage) return;

    this.isIndustrialRunning = true;
    this.systemStatus.cameraStatus = '运行中';

    this.startCaptureTimer();
    this.startDurationTimer();
  }

  pauseIndustrialDetection() {
    this.stopCaptureTimer();
    this.isIndustrialRunning = false;
    this.systemStatus.cameraStatus = '已暂停';
  }

  resumeIndustrialDetection() {
    this.isIndustrialRunning = true;
    this.systemStatus.cameraStatus = '运行中';
    this.startCaptureTimer();
  }

  stopIndustrialDetection() {
    this.stopCaptureTimer();
    this.stopDurationTimer();
    this.isIndustrialRunning = false;
    this.isAnalyzingCurrent = false;
    this.systemStatus.cameraStatus = '已停止';

    try {
      if (this.captureSession) {
        this.captureSession.stop();
        this.captureSession.release();
        this.captureSession = null;
      }
      this.cameraManager = null;
      this.photoOutput = null;
    } catch (err) {
      console.error('释放相机失败:', err);
    }
  }

  startCaptureTimer() {
    this.stopCaptureTimer();
    // 首次延迟1秒开始，之后按间隔执行
    setTimeout(() => {
      this.autoCapture();
      this.captureTimer = setInterval(() => {
        this.autoCapture();
      }, this.industrialConfig.captureInterval * 1000);
    }, 1000);
  }

  stopCaptureTimer() {
    if (this.captureTimer !== -1) {
      clearInterval(this.captureTimer);
      this.captureTimer = -1;
    }
  }

  startDurationTimer() {
    this.stopDurationTimer();
    this.durationTimer = setInterval(() => {
      if (this.sessionStats.sessionStart > 0) {
        const elapsed = Math.floor((Date.now() - this.sessionStats.sessionStart) / 1000);
        const h = Math.floor(elapsed / 3600);
        const m = Math.floor((elapsed % 3600) / 60);
        const s = elapsed % 60;
        this.sessionDuration = `${this.padZero(h)}:${this.padZero(m)}:${this.padZero(s)}`;
      }
    }, 1000);
  }

  stopDurationTimer() {
    if (this.durationTimer !== -1) {
      clearInterval(this.durationTimer);
      this.durationTimer = -1;
    }
  }

  async autoCapture() {
    if (this.isAnalyzingCurrent || !this.photoOutput) return;
    try {
      await this.photoOutput.capture();
    } catch (err) {
      console.error('自动拍照失败:', err);
    }
  }

  formatTime(date: Date): string {
    return `${this.padZero(date.getHours())}:${this.padZero(date.getMinutes())}:${this.padZero(date.getSeconds())}`;
  }

  padZero(n: number): string {
    return n < 10 ? `0${n}` : `${n}`;
  }

  // ===== 构建UI =====
  build() {
    Column() {
      // 顶部导航栏
      Row() {
        Text('能效标签检测系统')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor('#ffffff')
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });

        // 模式切换
        Row() {
          Text('手动')
            .fontSize(12)
            .fontColor(this.currentMode === 'manual' ? '#2B6CB0' : '#ffffff')
            .fontWeight(this.currentMode === 'manual' ? FontWeight.Bold : FontWeight.Normal)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .backgroundColor(this.currentMode === 'manual' ? '#ffffff' : 'rgba(255,255,255,0)')
            .borderRadius(10)
            .onClick(() => this.handleModeSwitch('manual'));
          Text('产线')
            .fontSize(12)
            .fontColor(this.currentMode === 'industrial' ? '#2B6CB0' : '#ffffff')
            .fontWeight(this.currentMode === 'industrial' ? FontWeight.Bold : FontWeight.Normal)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .backgroundColor(this.currentMode === 'industrial' ? '#ffffff' : 'rgba(255,255,255,0)')
            .borderRadius(10)
            .onClick(() => this.handleModeSwitch('industrial'));
        }
        .backgroundColor('rgba(255,255,255,0.2)')
        .borderRadius(12)
        .margin({ right: 8 });

        Button('设置')
          .fontSize(12)
          .fontColor('#ffffff')
          .height(28)
          .padding({ left: 12, right: 12 })
          .backgroundColor('rgba(255, 255, 255, 0.2)')
          .borderRadius(14)
          .onClick(() => {
            router.pushUrl({ url: 'pages/Settings' });
          });
        Button('历史')
          .fontSize(12)
          .fontColor('#ffffff')
          .height(28)
          .padding({ left: 12, right: 12 })
          .backgroundColor('rgba(255, 255, 255, 0.2)')
          .borderRadius(14)
          .margin({ left: 8 })
          .onClick(() => {
            router.pushUrl({ url: 'pages/History' });
          });
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .linearGradient({
        direction: GradientDirection.Right,
        colors: [['#2B6CB0', 0], ['#4299E1', 1]]
      });

      // 条件渲染：按模式切换
      if (this.currentMode === 'manual') {
        this.ManualModeContent();
      } else {
        this.IndustrialModeContent();
      }

      // 底部状态栏
      if (this.currentMode === 'manual') {
        Row() {
          Text(`状态: ${this.systemStatus.cameraStatus}`)
            .fontSize(11)
            .fontColor('#4a5568')
            .layoutWeight(1)
            .textAlign(TextAlign.Center);
          Text(`耗时: ${this.systemStatus.detectionSpeed}`)
            .fontSize(11)
            .fontColor('#4a5568')
            .layoutWeight(1)
            .textAlign(TextAlign.Center);
          Text(`等级: ${this.detectionResult ? GRADE_NAMES[this.detectionResult.grade] || '-' : '-'}`)
            .fontSize(11)
            .fontColor('#4a5568')
            .layoutWeight(1)
            .textAlign(TextAlign.Center);
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .backgroundColor('#ffffff')
        .border({ width: { top: 1 }, color: '#e2e8f0' });
      } else {
        Row() {
          Text(`相机: ${this.systemStatus.cameraStatus}`)
            .fontSize(11)
            .fontColor('#4a5568')
            .layoutWeight(1)
            .textAlign(TextAlign.Center);
          Text(`总数: ${this.sessionStats.totalCaptures}`)
            .fontSize(11)
            .fontColor('#4a5568')
            .layoutWeight(1)
            .textAlign(TextAlign.Center);
          Text(`通过率: ${this.sessionStats.passRate}%`)
            .fontSize(11)
            .fontColor('#4a5568')
            .layoutWeight(1)
            .textAlign(TextAlign.Center);
          Text(`运行: ${this.sessionDuration}`)
            .fontSize(11)
            .fontColor('#4a5568')
            .layoutWeight(1)
            .textAlign(TextAlign.Center);
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .backgroundColor('#ffffff')
        .border({ width: { top: 1 }, color: '#e2e8f0' });
      }

      // 测试图片弹窗（仅手动模式）
      if (this.showTestPicker) {
        this.TestImagePicker();
      }
    }
    .height('100%')
    .width('100%')
    .backgroundColor('#f0f4f8');
  }

  // ===== 手动模式内容 =====
  @Builder ManualModeContent() {
    Scroll() {
      Column() {
        // 图片预览区域
        Column() {
          Text('图片预览')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor('#1a365d')
            .margin({ bottom: 8 });

          Stack() {
            if (this.selectedImageUri) {
              Image(this.selectedImageUri)
                .width('100%')
                .height('100%')
                .objectFit(ImageFit.Contain)
                .borderRadius(8);
            } else {
              Column() {
                Text('请选择图片或拍照')
                  .fontSize(14)
                  .fontColor('#a0aec0');
                Text('支持 JPG/PNG 格式')
                  .fontSize(12)
                  .fontColor('#cbd5e0')
                  .margin({ top: 4 });
              }
              .justifyContent(FlexAlign.Center);
            }

            if (this.isAnalyzing) {
              Column() {
                LoadingProgress()
                  .width(40)
                  .height(40)
                  .color('#ffffff');
                Text('正在检测...')
                  .fontSize(14)
                  .fontColor('#ffffff')
                  .margin({ top: 8 });
              }
              .width('100%')
              .height('100%')
              .backgroundColor('rgba(0, 0, 0, 0.5)')
              .borderRadius(8)
              .justifyContent(FlexAlign.Center);
            }

            if (this.detectionResult && !this.isAnalyzing) {
              Text(this.detectionResult.isPass ? '检测通过' : '检测未通过')
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.detectionResult.isPass ? '#38a169' : '#e53e3e')
                .backgroundColor('rgba(255, 255, 255, 0.9)')
                .padding({ left: 16, right: 16, top: 6, bottom: 6 })
                .borderRadius(20);
            }
          }
          .width('100%')
          .height(200)
          .borderRadius(8)
          .backgroundColor('#e2e8f0')
          .alignContent(Alignment.Center);

          // 操作按钮
          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start, alignContent: FlexAlign.Start }) {
            Button('选择图片')
              .fontSize(13)
              .fontColor('#ffffff')
              .height(36)
              .backgroundColor('#3182ce')
              .borderRadius(8)
              .margin({ right: 8, bottom: 8 })
              .onClick(() => this.handleSelectImage());

            Button('拍照')
              .fontSize(13)
              .fontColor('#ffffff')
              .height(36)
              .backgroundColor('#805ad5')
              .borderRadius(8)
              .margin({ right: 8, bottom: 8 })
              .onClick(() => this.handleOpenCamera());

            Button('测试图片')
              .fontSize(13)
              .fontColor('#ffffff')
              .height(36)
              .backgroundColor('#d69e2e')
              .borderRadius(8)
              .margin({ right: 8, bottom: 8 })
              .onClick(() => { this.showTestPicker = true; });

            Button('分析')
              .fontSize(13)
              .fontColor('#ffffff')
              .height(36)
              .backgroundColor(this.isAnalyzing ? '#a0aec0' : '#38a169')
              .borderRadius(8)
              .margin({ bottom: 8 })
              .enabled(!this.isAnalyzing)
              .onClick(() => this.handleAnalyze());
          }
          .width('100%')
          .margin({ top: 12 });

          if (this.errorMessage) {
            Text(this.errorMessage)
              .fontSize(12)
              .fontColor('#e53e3e')
              .margin({ top: 8 })
              .width('100%');
          }
        }
        .width('100%')
        .padding(12)
        .backgroundColor('#ffffff')
        .borderRadius(12);

        if (this.detectionResult) {
          this.DefectCard();
          if (!this.detectionResult.hasDefect) {
            this.GradeCard();
            this.ResultCard();
          }
          this.PositionCard();
        }
      }
      .padding(12);
    }
    .layoutWeight(1)
    .scrollBar(BarState.Off);
  }

  // ===== 产线模式内容 =====
  @Builder IndustrialModeContent() {
    Column() {
      // 相机预览 + 实时统计
      Row() {
        // 左：相机预览
        Stack() {
          if (this.isIndustrialRunning || this.sessionStats.sessionStart > 0) {
            XComponent({
              id: 'industrialCamera',
              type: 'surface',
              controller: this.xComponentController
            })
              .width('100%')
              .height('100%')
              .onLoad(() => {
                // 仅首次启动时初始化相机
              });
          } else {
            Column() {
              Text('工业相机')
                .fontSize(14)
                .fontColor('#a0aec0');
              Text('点击"开始"启动相机')
                .fontSize(12)
                .fontColor('#cbd5e0')
                .margin({ top: 4 });
            }
            .justifyContent(FlexAlign.Center);
          }

          // 分析中指示
          if (this.isAnalyzingCurrent) {
            Column() {
              LoadingProgress()
                .width(30)
                .height(30)
                .color('#ffffff');
              Text('分析中')
                .fontSize(12)
                .fontColor('#ffffff')
                .margin({ top: 4 });
            }
            .backgroundColor('rgba(0,0,0,0.5)')
            .padding(8)
            .borderRadius(8);
          }

          // 暂停指示
          if (!this.isIndustrialRunning && this.sessionStats.sessionStart > 0) {
            Text('已暂停')
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor('#ffffff')
              .backgroundColor('rgba(0,0,0,0.6)')
              .padding({ left: 16, right: 16, top: 6, bottom: 6 })
              .borderRadius(6);
          }
        }
        .width('55%')
        .height(220)
        .borderRadius(8)
        .backgroundColor('#1a1a2e')
        .alignContent(Alignment.Center);

        // 右：实时统计面板
        Column() {
          Text('实时统计')
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1a365d')
            .margin({ bottom: 8 });

          Row() {
            this.StatBox('检测总数', `${this.sessionStats.totalCaptures}`, '#3182ce');
            this.StatBox('通过率', `${this.sessionStats.passRate}%`, '#38a169');
          }
          .width('100%')
          .justifyContent(FlexAlign.SpaceAround);

          Row() {
            this.StatBox('通过', `${this.sessionStats.passCount}`, '#38a169');
            this.StatBox('未通过', `${this.sessionStats.failCount}`, '#e53e3e');
          }
          .width('100%')
          .justifyContent(FlexAlign.SpaceAround)
          .margin({ top: 6 });

          // 缺陷统计
          Column() {
            Text('缺陷统计')
              .fontSize(11)
              .fontColor('#718096')
              .margin({ bottom: 4 });
            Row() {
              Text(`破损 ${this.sessionStats.defectDamaged}`)
                .fontSize(11)
                .fontColor('#e53e3e')
                .layoutWeight(1)
                .textAlign(TextAlign.Center);
              Text(`污渍 ${this.sessionStats.defectStained}`)
                .fontSize(11)
                .fontColor('#d69e2e')
                .layoutWeight(1)
                .textAlign(TextAlign.Center);
              Text(`褶皱 ${this.sessionStats.defectWrinkled}`)
                .fontSize(11)
                .fontColor('#805ad5')
                .layoutWeight(1)
                .textAlign(TextAlign.Center);
            }
            .width('100%');
          }
          .width('100%')
          .padding(8)
          .backgroundColor('#f7fafc')
          .borderRadius(6)
          .margin({ top: 8 });

          Text(`平均耗时: ${this.sessionStats.averageTime}ms`)
            .fontSize(11)
            .fontColor('#718096')
            .margin({ top: 6 });

          Text(`运行: ${this.sessionDuration}`)
            .fontSize(11)
            .fontColor('#718096')
            .margin({ top: 4 });
        }
        .width('45%')
        .height(220)
        .padding(10)
        .backgroundColor('#ffffff')
        .borderRadius(8)
        .alignItems(HorizontalAlign.Center);
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 12 });

      // 控制栏
      Column() {
        Row() {
          if (!this.isIndustrialRunning && this.sessionStats.sessionStart === 0) {
            // 未启动状态 → 显示"开始"
            Button('开始')
              .fontSize(14)
              .fontColor('#ffffff')
              .height(36)
              .backgroundColor('#38a169')
              .borderRadius(8)
              .layoutWeight(1)
              .onClick(() => this.startIndustrialDetection());
          } else if (this.isIndustrialRunning) {
            // 运行中 → 显示"暂停"
            Button('暂停')
              .fontSize(14)
              .fontColor('#ffffff')
              .height(36)
              .backgroundColor('#d69e2e')
              .borderRadius(8)
              .layoutWeight(1)
              .onClick(() => this.pauseIndustrialDetection());
          } else {
            // 已暂停 → 显示"继续"
            Button('继续')
              .fontSize(14)
              .fontColor('#ffffff')
              .height(36)
              .backgroundColor('#38a169')
              .borderRadius(8)
              .layoutWeight(1)
              .onClick(() => this.resumeIndustrialDetection());
          }

          Button('结束')
            .fontSize(14)
            .fontColor('#4a5568')
            .height(36)
            .backgroundColor('#e2e8f0')
            .borderRadius(8)
            .margin({ left: 8 })
            .enabled(this.sessionStats.sessionStart > 0)
            .onClick(() => this.stopIndustrialDetection());
        }
        .width('100%');

        // 间隔选择
        Row() {
          Text('拍照间隔:')
            .fontSize(12)
            .fontColor('#4a5568')
            .margin({ right: 8 });
          ForEach([5, 10, 30, 60], (interval: number) => {
            Text(`${interval}s`)
              .fontSize(12)
              .fontColor(this.industrialConfig.captureInterval === interval ? '#ffffff' : '#4a5568')
              .fontWeight(this.industrialConfig.captureInterval === interval ? FontWeight.Bold : FontWeight.Normal)
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .backgroundColor(this.industrialConfig.captureInterval === interval ? '#3182ce' : '#edf2f7')
              .borderRadius(10)
              .margin({ left: 4 })
              .onClick(() => {
                this.industrialConfig.captureInterval = interval;
                // 如果正在运行，重新启动定时器
                if (this.isIndustrialRunning) {
                  this.startCaptureTimer();
                }
              });
          }, (interval: number) => `${interval}`);
        }
        .width('100%')
        .margin({ top: 8 });

        // 错误信息
        if (this.industrialMessage) {
          Text(this.industrialMessage)
            .fontSize(12)
            .fontColor('#e53e3e')
            .margin({ top: 4 })
            .width('100%');
        }
      }
      .width('100%')
      .padding(12)
      .backgroundColor('#ffffff')
      .borderRadius(12)
      .margin({ left: 12, right: 12, top: 8 });

      // 最近检测结果
      Scroll() {
        Column() {
          if (this.recentResults.length === 0) {
            Column() {
              Text('暂无检测记录')
                .fontSize(14)
                .fontColor('#a0aec0')
                .margin({ top: 20 });
            }
            .width('100%')
            .height(80)
            .justifyContent(FlexAlign.Center);
          }

          ForEach(this.recentResults, (record: AutoDetectionRecord) => {
            this.IndustrialResultRow(record);
          }, (record: AutoDetectionRecord) => `${record.id}`)
        }
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .padding({ left: 12, right: 12, bottom: 8 });
    }
    .layoutWeight(1);
  }

  // ===== 统计小方块 =====
  @Builder StatBox(label: string, value: string, color: string) {
    Column() {
      Text(value)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(color);
      Text(label)
        .fontSize(10)
        .fontColor('#718096')
        .margin({ top: 2 });
    }
    .alignItems(HorizontalAlign.Center);
  }

  // ===== 产线模式检测记录行 =====
  @Builder IndustrialResultRow(record: AutoDetectionRecord) {
    Row() {
      // 编号和时间
      Column() {
        Text(`#${record.id}`)
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1a365d');
        Text(record.timestamp)
          .fontSize(10)
          .fontColor('#a0aec0')
          .margin({ top: 2 });
      }
      .width(60)
      .alignItems(HorizontalAlign.Start);

      // 结果信息
      Column() {
        if (record.status === 'completed' && record.result) {
          Row() {
            Text(`等级: ${record.result.grade > 0 ? record.result.grade + '级' : '-'}`)
              .fontSize(12)
              .fontColor('#4a5568');
            Text(record.result.isPass ? '通过' : '未通过')
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .fontColor(record.result.isPass ? '#38a169' : '#e53e3e')
              .margin({ left: 12 });
          }
          // 缺陷标签
          if (record.result.hasDefect) {
            Row() {
              if (record.result.defects.isDamaged) {
                Text('破损')
                  .fontSize(10)
                  .fontColor('#e53e3e')
                  .backgroundColor('#fed7d7')
                  .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                  .borderRadius(4)
                  .margin({ right: 4 });
              }
              if (record.result.defects.isStained) {
                Text('污渍')
                  .fontSize(10)
                  .fontColor('#d69e2e')
                  .backgroundColor('#fefcbf')
                  .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                  .borderRadius(4)
                  .margin({ right: 4 });
              }
              if (record.result.defects.isWrinkled) {
                Text('褶皱')
                  .fontSize(10)
                  .fontColor('#805ad5')
                  .backgroundColor('#e9d8fd')
                  .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                  .borderRadius(4);
              }
            }
            .margin({ top: 4 });
          }
        } else if (record.status === 'failed') {
          Text(`分析失败: ${record.errorMessage}`)
            .fontSize(12)
            .fontColor('#e53e3e');
        } else {
          Row() {
            LoadingProgress()
              .width(14)
              .height(14)
              .color('#3182ce');
            Text('分析中...')
              .fontSize(12)
              .fontColor('#718096')
              .margin({ left: 6 });
          }
        }
      }
      .layoutWeight(1)
      .margin({ left: 8 });
    }
    .width('100%')
    .padding({ top: 8, bottom: 8, left: 10, right: 10 })
    .backgroundColor('#ffffff')
    .borderRadius(8)
    .margin({ bottom: 4 })
    .border({ width: 1, color: '#edf2f7' });
  }

  // ===== 能效等级卡片 =====
  @Builder GradeCard() {
    Column() {
      Row() {
        Row() {
          Row()
            .width(3)
            .height(14)
            .backgroundColor('#38a169')
            .borderRadius(2);
        }
        .margin({ right: 8 });
        Text('能效等级')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#1a365d')
          .layoutWeight(1);
        if (this.detectionResult) {
          Text(this.detectionResult.isPass ? '合格' : '不合格')
            .fontSize(11)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.detectionResult.isPass ? '#38a169' : '#e53e3e')
            .backgroundColor(this.detectionResult.isPass ? '#c6f6d5' : '#fed7d7')
            .padding({ left: 10, right: 10, top: 3, bottom: 3 })
            .borderRadius(10);
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: 10 });

      if (this.detectionResult && this.detectionResult.grade > 0) {
        Row() {
          Column() {
            Text(`${this.detectionResult.grade}`)
              .fontSize(48)
              .fontWeight(FontWeight.Bold)
              .fontColor(GRADE_COLORS[this.detectionResult.grade] || '#1a365d');
            Text('级')
              .fontSize(14)
              .fontColor('#718096');
          }
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .width(100)
          .height(100)
          .backgroundColor(GRADE_BG_COLORS[this.detectionResult.grade] || '#f7fafc')
          .borderRadius(12);

          Column() {
            ForEach([1, 2, 3, 4, 5], (g: number) => {
              Row() {
                Row()
                  .width(g === this.detectionResult?.grade ? 24 : 16)
                  .height(8)
                  .backgroundColor(GRADE_COLORS[g])
                  .borderRadius(4);
                Text(`${g}级`)
                  .fontSize(11)
                  .fontColor(g === this.detectionResult?.grade ? '#1a365d' : '#a0aec0')
                  .fontWeight(g === this.detectionResult?.grade ? FontWeight.Bold : FontWeight.Normal)
                  .margin({ left: 6 });
              }
              .width('100%')
              .padding({ left: 8, right: 8, top: 4, bottom: 4 });
            });
          }
          .layoutWeight(1)
          .padding({ left: 16 });
        }
        .width('100%');

        Row() {
          Text('检测方式:')
            .fontSize(12)
            .fontColor('#718096');
          Text(this.detectionResult.gradeMethod === 'color' ? '颜色分析' : 'OCR识别')
            .fontSize(12)
            .fontColor('#4a5568')
            .margin({ left: 4 });
          Text('  置信度:')
            .fontSize(12)
            .fontColor('#718096');
          Text(`${Math.round(this.detectionResult.gradeConfidence * 100)}%`)
            .fontSize(12)
            .fontColor('#4a5568')
            .margin({ left: 4 });
        }
        .width('100%')
        .margin({ top: 8 });
      } else {
        Text('未检测到能效等级')
          .fontSize(14)
          .fontColor('#e53e3e')
          .margin({ top: 8 });
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#ffffff')
    .borderRadius(12)
    .margin({ top: 10 });
  }

  // ===== 参数识别卡片 =====
  @Builder ResultCard() {
    Column() {
      Row() {
        Row() {
          Row()
            .width(3)
            .height(14)
            .backgroundColor('#3182ce')
            .borderRadius(2);
        }
        .margin({ right: 8 });
        Text('参数识别')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#1a365d')
          .layoutWeight(1);
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: 10 });

      Column() {
        Row() {
          Text('能效参数')
            .fontSize(13)
            .fontColor('#718096')
            .width('28%');
          Text(this.detectionResult?.energyParam || '-')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor('#1a365d')
            .layoutWeight(1);
        }
        .width('100%')
        .margin({ bottom: 8 });
        Row() {
          Text('待机功率')
            .fontSize(13)
            .fontColor('#718096')
            .width('28%');
          Text(this.detectionResult?.standbyPower || '-')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor('#1a365d')
            .layoutWeight(1);
        }
        .width('100%')
        .margin({ bottom: 8 });
        Row() {
          Text('标签识别')
            .fontSize(13)
            .fontColor('#718096')
            .width('28%');
          Text(this.detectionResult?.labelFound ? '已识别' : '未识别')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.detectionResult?.labelFound ? '#38a169' : '#e53e3e')
            .layoutWeight(1);
        }
        .width('100%');
      }
      .width('100%')
      .padding(10)
      .backgroundColor('#f7fafc')
      .borderRadius(8);
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#ffffff')
    .borderRadius(12)
    .margin({ top: 10 });
  }

  // ===== 缺陷检测卡片 =====
  @Builder DefectCard() {
    Column() {
      Row() {
        Row() {
          Row()
            .width(3)
            .height(14)
            .backgroundColor('#e53e3e')
            .borderRadius(2);
        }
        .margin({ right: 8 });
        Text('缺陷检测')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#1a365d');
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: 10 });

      Row() {
        Column() {
          Text('破损')
            .fontSize(11)
            .fontColor('#718096')
            .margin({ bottom: 4 });
          Text(this.detectionResult?.defects.isDamaged ? '存在' : '正常')
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.detectionResult?.defects.isDamaged ? '#e53e3e' : '#38a169');
        }
        .layoutWeight(1)
        .padding(10)
        .backgroundColor('#f7fafc')
        .borderRadius(8)
        .alignItems(HorizontalAlign.Center);

        Column() {
          Text('污渍')
            .fontSize(11)
            .fontColor('#718096')
            .margin({ bottom: 4 });
          Text(this.detectionResult?.defects.isStained ? '存在' : '正常')
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.detectionResult?.defects.isStained ? '#e53e3e' : '#38a169');
        }
        .layoutWeight(1)
        .padding(10)
        .backgroundColor('#f7fafc')
        .borderRadius(8)
        .alignItems(HorizontalAlign.Center)
        .margin({ left: 8 });

        Column() {
          Text('褶皱')
            .fontSize(11)
            .fontColor('#718096')
            .margin({ bottom: 4 });
          Text(this.detectionResult?.defects.isWrinkled ? '存在' : '正常')
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.detectionResult?.defects.isWrinkled ? '#e53e3e' : '#38a169');
        }
        .layoutWeight(1)
        .padding(10)
        .backgroundColor('#f7fafc')
        .borderRadius(8)
        .alignItems(HorizontalAlign.Center)
        .margin({ left: 8 });
      }
      .width('100%');
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#ffffff')
    .borderRadius(12)
    .margin({ top: 10 });
  }

  // ===== 位置检测卡片 =====
  @Builder PositionCard() {
    Column() {
      Row() {
        Row() {
          Row()
            .width(3)
            .height(14)
            .backgroundColor('#805ad5')
            .borderRadius(2);
        }
        .margin({ right: 8 });
        Text('位置检测')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#1a365d')
          .layoutWeight(1);
        Text(this.detectionResult?.position.isCorrect ? '正确' : '偏移')
          .fontSize(11)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.detectionResult?.position.isCorrect ? '#38a169' : '#e53e3e')
          .backgroundColor(this.detectionResult?.position.isCorrect ? '#c6f6d5' : '#fed7d7')
          .padding({ left: 10, right: 10, top: 3, bottom: 3 })
          .borderRadius(10);
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: 10 });

      Row() {
        Column() {
          Text('X坐标')
            .fontSize(11)
            .fontColor('#718096')
            .margin({ bottom: 4 });
          Text(`${this.detectionResult?.position.x}px`)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1a365d');
        }
        .layoutWeight(1)
        .padding(10)
        .backgroundColor('#f7fafc')
        .borderRadius(8)
        .alignItems(HorizontalAlign.Center);

        Column() {
          Text('Y坐标')
            .fontSize(11)
            .fontColor('#718096')
            .margin({ bottom: 4 });
          Text(`${this.detectionResult?.position.y}px`)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1a365d');
        }
        .layoutWeight(1)
        .padding(10)
        .backgroundColor('#f7fafc')
        .borderRadius(8)
        .alignItems(HorizontalAlign.Center)
        .margin({ left: 8 });

        Column() {
          Text('偏差')
            .fontSize(11)
            .fontColor('#718096')
            .margin({ bottom: 4 });
          Text(`${this.detectionResult?.position.deviation}%`)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1a365d');
        }
        .layoutWeight(1)
        .padding(10)
        .backgroundColor('#f7fafc')
        .borderRadius(8)
        .alignItems(HorizontalAlign.Center)
        .margin({ left: 8 });
      }
      .width('100%');
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#ffffff')
    .borderRadius(12)
    .margin({ top: 10 });
  }

  // ===== 测试图片选择弹窗 =====
  @Builder TestImagePicker() {
    Column() {
      Column() {
      }
      .width('100%')
      .layoutWeight(1)
      .onClick(() => { this.showTestPicker = false; });

      Column() {
        Text('选择测试图片')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1a365d')
          .margin({ bottom: 8 });

        Scroll() {
          Column() {
            ForEach(this.testImageGroups, (group: TestImageGroup) => {
              Column() {
                Text(group.title)
                  .fontSize(12)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#4a5568')
                  .padding({ top: 8, bottom: 4 });

                ForEach(group.images, (item: TestImageItem) => {
                  Row() {
                    Column() {
                      Text(item.name)
                        .fontSize(12)
                        .fontWeight(FontWeight.Medium)
                        .fontColor('#1a365d');
                      Text(item.desc)
                        .fontSize(10)
                        .fontColor('#a0aec0')
                        .margin({ top: 1 });
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1);

                    Text('加载')
                      .fontSize(11)
                      .fontColor('#3182ce')
                      .fontWeight(FontWeight.Medium)
                      .onClick(() => {
                        this.handleLoadTestImage(item.file);
                      });
                  }
                  .width('100%')
                  .padding({ top: 6, bottom: 6 })
                  .border({ width: { bottom: 1 }, color: '#edf2f7' });
                }, (item: TestImageItem) => item.file)
              }
              .width('100%');
            }, (group: TestImageGroup) => group.title)
          }
        }
        .height(360)
        .scrollBar(BarState.Auto);

        Button('关闭')
          .fontSize(13)
          .fontColor('#4a5568')
          .width('100%')
          .height(34)
          .backgroundColor('#e2e8f0')
          .borderRadius(8)
          .margin({ top: 8 })
          .onClick(() => {
            this.showTestPicker = false;
          });
      }
      .padding(16)
      .backgroundColor('#ffffff')
      .borderRadius({ topLeft: 16, topRight: 16 })
      .width('100%');

      Column()
        .width('100%')
        .height(20);
    }
    .width('100%')
    .height('100%')
    .position({ x: 0, y: 0 })
    .backgroundColor('rgba(0, 0, 0, 0.5)')
    .justifyContent(FlexAlign.End);
  }
}

interface TestImageItem {
  name: string;
  file: string;
  desc: string;
}

interface TestImageGroup {
  title: string;
  images: TestImageItem[];
}

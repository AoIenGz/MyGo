"""
能效标签检测 API 脚本
整合 YOLO 缺陷检测 + 颜色等级识别 + OCR 参数提取
输入: sys.argv[1] = 图片路径
输出: JSON 格式检测结果到 stdout
"""
import sys
import os
import json
import re
import io
import cv2
import numpy as np

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding='utf-8', errors='replace')

# 模型路径：优先使用项目内模型，回退到原训练目录
_MODEL_CANDIDATES = [
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "best.pt"),
    r"D:\yolo_test\train\weights\best.pt",
]
MODEL_PATH = next((p for p in _MODEL_CANDIDATES if os.path.exists(p)), _MODEL_CANDIDATES[-1])


def load_model():
    from ultralytics import YOLO
    return YOLO(MODEL_PATH)


# ========== 颜色等级检测 (v5 算法, 87% 准确率) ==========

def hue_to_grade(hue):
    if hue > 168 or hue < 12:
        return 5
    elif 12 <= hue < 24:
        return 4
    elif 24 <= hue < 36:
        return 3
    elif 36 <= hue < 65:
        return 2
    elif 65 <= hue <= 105:
        return 1
    return None


def _analyze_roi(hsv, roi_h, roi_w, sat_thr):
    right_edges = np.zeros(roi_h)
    for y in range(roi_h):
        row = hsv[y]
        mask = (row[:, 1] > sat_thr) & (row[:, 2] > 60)
        colored = np.where(mask)[0]
        if len(colored) >= 3:
            right_edges[y] = colored[-1]

    # 跳过绿色标题栏
    grade_start = 0
    in_header = False
    for y in range(roi_h):
        if right_edges[y] > roi_w * 0.3:
            in_header = True
        elif in_header and right_edges[y] < roi_w * 0.15:
            for y2 in range(y, roi_h):
                if right_edges[y2] > roi_w * 0.15:
                    grade_start = y2
                    break
            break

    search_end = min(roi_h, grade_start + 80)
    grade_edges = right_edges[grade_start:search_end]
    grade_h = len(grade_edges)

    if grade_h < 10:
        return None, {"grade_start": int(grade_start), "error": "short"}

    nonzero = grade_edges[grade_edges > 0]
    if len(nonzero) < 5:
        return None, {"error": "no_color"}

    median_edge = float(np.median(nonzero))
    arrow_threshold = median_edge * 1.3

    arrow_mask = grade_edges > arrow_threshold
    arrow_indices = np.where(arrow_mask)[0]

    debug = {
        "grade_start": int(grade_start),
        "median_edge": round(median_edge, 1),
        "arrow_threshold": round(arrow_threshold, 1),
        "arrow_count": len(arrow_indices),
    }

    if len(arrow_indices) < 3:
        return None, {**debug, "error": "no_arrow"}

    # 采样箭头行高饱和度像素的色调
    all_hues = []
    hue_sample_thr = max(sat_thr, 50)
    for idx in arrow_indices:
        actual_y = grade_start + idx
        row = hsv[actual_y]
        hi_mask = (row[:, 1] > hue_sample_thr) & (row[:, 2] > 50)
        hi_pixels = np.where(hi_mask)[0]
        if len(hi_pixels) >= 3:
            hues = row[hi_pixels, 0]
            all_hues.extend(hues.tolist())

    if len(all_hues) < 10:
        return None, {**debug, "error": "few_hues"}

    hue_array = np.array(all_hues)

    # 色调直方图判断等级
    bins = [0, 0, 0, 0, 0]
    for hue_val in hue_array:
        h = float(hue_val)
        if h > 168 or h < 12:
            bins[4] += 1
        elif 12 <= h < 24:
            bins[3] += 1
        elif 24 <= h < 36:
            bins[2] += 1
        elif 36 <= h < 65:
            bins[1] += 1
        elif 65 <= h <= 105:
            bins[0] += 1

    total_pixels = sum(bins)
    debug["hue_bins"] = {f"G{i+1}": b for i, b in enumerate(bins)}
    debug["hue_median"] = round(float(np.median(hue_array)), 1)

    best_bin = bins.index(max(bins))
    grade = best_bin + 1
    debug["grade"] = int(grade)
    debug["confidence"] = round(max(bins) / total_pixels, 2) if total_pixels > 0 else 0

    return grade, debug


def _detect_with_roi(crop, ry1, ry2, rx2):
    h, w = crop.shape[:2]
    roi = crop[int(h * ry1):int(h * ry2), 0:int(w * rx2)]
    roi_h, roi_w = roi.shape[:2]

    if roi_h < 20 or roi_w < 20:
        return None, {"error": "roi_small"}

    hsv = cv2.cvtColor(roi, cv2.COLOR_BGR2HSV)

    for sat_thr in [40, 25, 15]:
        result = _analyze_roi(hsv, roi_h, roi_w, sat_thr)
        if result[0] is not None:
            result[1]["sat_thr"] = sat_thr
            return result

    return None, {"error": "sat_adaptive_failed"}


def detect_grade(crop):
    """颜色检测能效等级 1-5，带回退机制"""
    grade, debug = _detect_with_roi(crop, 0.08, 0.58, 0.58)
    if grade is not None:
        return grade, debug

    grade2, debug2 = _detect_with_roi(crop, 0.05, 0.65, 0.60)
    if grade2 is not None:
        debug2["fallback"] = "wide_roi"
        return grade2, debug2

    grade3, debug3 = _detect_with_roi(crop, 0.10, 0.55, 0.55)
    if grade3 is not None:
        debug3["fallback"] = "original_roi"
        return grade3, debug3

    ch, cw = crop.shape[:2]
    big_crop = cv2.resize(crop, (cw * 4, ch * 4), interpolation=cv2.INTER_CUBIC)
    grade4, debug4 = _detect_with_roi(big_crop, 0.08, 0.58, 0.58)
    if grade4 is not None:
        debug4["fallback"] = "upscaled_4x"
        return grade4, debug4

    grade5, debug5 = _detect_with_roi(crop, 0.05, 0.75, 0.70)
    if grade5 is not None:
        debug5["fallback"] = "wide_search"
        return grade5, debug5

    return None, {**debug, "error": "all_failed"}


# ========== OCR 参数提取 ==========

def extract_ocr(crop):
    """PaddleOCR 提取能效参数和待机功率"""
    try:
        from paddleocr import PaddleOCR

        ocr = PaddleOCR(use_angle_cls=True, lang='ch', show_log=False)

        # 放大4倍提高 OCR 精度
        h, w = crop.shape[:2]
        big_crop = cv2.resize(crop, (w * 4, h * 4), interpolation=cv2.INTER_CUBIC)

        result = ocr.ocr(big_crop, cls=True)

        if not result or not result[0]:
            return {'texts': [], 'energy_param': None, 'standby_power': None, 'grade_from_ocr': None}

        texts = []
        for line in result[0]:
            text = line[1][0]
            confidence = round(line[1][1], 3)
            texts.append({'text': text, 'confidence': confidence})

        energy_param = None
        standby_power = None
        grade_from_ocr = None

        for item in texts:
            t = item['text']
            c = item['confidence']

            # 查找 X.X 格式的数字（能效参数和待机功率）
            decimal_matches = re.findall(r'\d+\.\d+', t)
            for dm in decimal_matches:
                val = float(dm)
                if val >= 0.01 and val <= 999:
                    if energy_param is None:
                        energy_param = val
                    elif standby_power is None:
                        standby_power = val

            # 高置信度单数字 1-5 → 等级辅助判断
            if c > 0.8 and len(t.strip()) == 1 and t.strip() in '12345':
                grade_from_ocr = int(t.strip())

        return {
            'texts': texts,
            'energy_param': energy_param,
            'standby_power': standby_power,
            'grade_from_ocr': grade_from_ocr
        }
    except ImportError:
        return {'error': 'PaddleOCR 未安装', 'texts': [], 'energy_param': None,
                'standby_power': None, 'grade_from_ocr': None}
    except Exception as e:
        return {'error': str(e), 'texts': [], 'energy_param': None,
                'standby_power': None, 'grade_from_ocr': None}


# ========== 主分析流程 ==========

def analyze_image(image_path):
    img = cv2.imread(image_path)
    if img is None:
        return {'success': False, 'error': '无法读取图片'}

    try:
        model = load_model()
    except Exception as e:
        return {'success': False, 'error': f'模型加载失败: {str(e)}'}

    results = model(image_path, verbose=False)

    detections = []
    best_label = None
    best_label_conf = 0
    best_label_bbox = None
    defects = {'isDamaged': False, 'isStained': False, 'isWrinkled': False}
    position = {'isCorrect': True, 'x': 0, 'y': 0, 'deviation': 0}
    has_label = False

    for result in results:
        for box in result.boxes:
            cls_name = result.names[int(box.cls[0])]
            conf = float(box.conf[0])
            x1, y1, x2, y2 = map(int, box.xyxy[0])

            detections.append({
                'class': cls_name,
                'confidence': round(conf, 3),
                'bbox': [x1, y1, x2, y2]
            })

            cls_lower = cls_name.lower()

            if cls_lower in ['label', 'nor']:
                has_label = True
                if conf > best_label_conf:
                    best_label = img[y1:y2, x1:x2]
                    best_label_conf = conf
                    best_label_bbox = [x1, y1, x2, y2]
                    img_h, img_w = img.shape[:2]
                    position['x'] = (x1 + x2) // 2
                    position['y'] = (y1 + y2) // 2
                    position['deviation'] = round(
                        abs((x1 + x2) / 2 - img_w / 2) / img_w * 100, 1)
                    position['isCorrect'] = position['deviation'] <= 10

            if cls_lower == 'break':
                defects['isDamaged'] = True
            elif cls_lower == 'stain':
                defects['isStained'] = True
            elif cls_lower == 'wrinkle':
                defects['isWrinkled'] = True

    if not has_label:
        return {
            'success': True,
            'grade': None,
            'gradeMethod': None,
            'gradeConfidence': None,
            'energyParam': None,
            'standbyPower': None,
            'defects': defects,
            'position': position,
            'isPass': False,
            'detections': detections,
            'labelFound': False,
            'hasDefect': any(defects.values()),
            'message': '未检测到能效标签'
        }

    # ===== 步骤1: 缺陷检测判定 =====
    has_defect = defects['isDamaged'] or defects['isStained'] or defects['isWrinkled']

    if has_defect:
        # 有缺陷 → 直接返回缺陷结果，不进行等级检测
        return {
            'success': True,
            'grade': None,
            'gradeMethod': None,
            'gradeConfidence': None,
            'energyParam': None,
            'standbyPower': None,
            'defects': defects,
            'position': position,
            'isPass': False,
            'detections': detections,
            'labelFound': True,
            'hasDefect': True,
            'labelConfidence': round(best_label_conf, 3),
            'labelBbox': best_label_bbox,
            'message': '检测到标签缺陷，跳过等级检测'
        }

    # ===== 步骤2: 无缺陷 → 颜色等级检测 =====
    grade = None
    grade_debug = None
    if best_label is not None and best_label.size > 0:
        grade, grade_debug = detect_grade(best_label)

    # ===== 步骤3: OCR 参数提取 =====
    ocr_result = None
    if best_label is not None and best_label.size > 0:
        ocr_result = extract_ocr(best_label)

    # 综合等级判定：优先颜色检测，回退 OCR
    final_grade = grade
    grade_method = 'color' if grade is not None else None
    grade_confidence = grade_debug.get('confidence') if grade_debug else None

    if final_grade is None and ocr_result and ocr_result.get('grade_from_ocr'):
        final_grade = ocr_result['grade_from_ocr']
        grade_method = 'ocr'

    energy_param = None
    standby_power = None
    if ocr_result:
        energy_param = ocr_result.get('energy_param')
        standby_power = ocr_result.get('standby_power')

    is_pass = final_grade is not None and position['isCorrect']

    return {
        'success': True,
        'grade': final_grade,
        'gradeMethod': grade_method,
        'gradeConfidence': grade_confidence,
        'energyParam': energy_param,
        'standbyPower': standby_power,
        'defects': defects,
        'position': position,
        'isPass': is_pass,
        'detections': detections,
        'labelFound': True,
        'hasDefect': False,
        'labelConfidence': round(best_label_conf, 3),
        'labelBbox': best_label_bbox,
        'labelCropSize': f"{best_label.shape[1]}x{best_label.shape[0]}" if best_label is not None else None
    }


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(json.dumps({'success': False, 'error': '未提供图片路径'}, ensure_ascii=False))
        sys.exit(1)

    image_path = sys.argv[1]
    if not os.path.exists(image_path):
        print(json.dumps({'success': False, 'error': f'图片不存在: {image_path}'}, ensure_ascii=False))
        sys.exit(1)

    result = analyze_image(image_path)
    print(json.dumps(result, ensure_ascii=False))

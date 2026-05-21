# smart_vision_app

Smart Vision Assist is a Flutter accessibility app with:

- Arabic and English localization with RTL support
- Text-to-speech across feature screens
- OCR with ML Kit and Gemini fallback for Arabic text
- Scene description with Gemini
- Emergency SMS and calling
- Voice-assisted navigation with live route lookup
- Speech-to-text destination input and voice commands
- TFLite obstacle-detection runtime wiring

## Setup

1. Add your Gemini key to `.env`:

```env
GEMINI_API_KEY=your_key_here
```

2. Optional for obstacle detection: place your model files in `assets/ml/`

- `assets/ml/obstacle_detection.tflite`
- `assets/ml/labels.txt`

3. Install packages:

```bash
flutter pub get
```

4. Run the app:

```bash
flutter run
```

## Demo Video

A full project presentation video is available through the link below.  
The video includes the graduation project slides, system explanation, screenshots, and demo videos showing the application features.

[Watch the Smart Vision Assist (FAVS) Demo Video](https://drive.google.com/drive/folders/153vXsETtsH_mxVvMae506TS3Sf5EIy2N?usp=sharing)

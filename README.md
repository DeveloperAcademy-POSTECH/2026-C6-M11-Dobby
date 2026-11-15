![착(chak) — 찍고, 재고, 올리는 일을 한 번에 착!](assets/readme/banner.png)

<h1>
  chak(착)&nbsp;
  <a href="https://apps.apple.com/kr/app/chak-%EC%B0%A9/id6823445800"><img src="assets/readme/app-store-badge.svg" height="40" align="center" alt="Download on the App Store"></a>&nbsp;
  <img src="https://img.shields.io/badge/iOS-26.0%2B-000000?style=flat&amp;logo=apple&amp;logoColor=white&amp;labelColor=000000" align="center" alt="iOS 26.0 이상">
  <img src="https://img.shields.io/badge/App-1.2.1-E34825?style=flat&amp;labelColor=E34825" align="center" alt="App 1.2.1">
</h1>

<!-- Apple 공식 다운로드 배지 원본: https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg -->
<!-- iOS 지원 버전과 앱 버전 배지는 App Store 공개 배포 버전 기준 -->

### 빈티지 의류의 촬영부터 판매 준비까지

착은 빈티지숍 운영자를 위한 iOS 앱입니다.<br>
한 벌의 사진과 실측, 상품 정보를 정리하고 판매 채널로 전달하는 과정을 돕습니다.

---

## ✨ 주요 기능

### 📸 촬영부터 실측까지

옷을 촬영해 실측 결과를 확인하고 측정점을 조정합니다. 제품의 디테일까지 추가로 촬영할 수 있습니다.

<table align="center">
  <tr>
    <td align="center"><img src="assets/readme/features/measurement-capture.png" width="240" alt="실측 촬영 화면"></td>
    <td align="center"><img src="assets/readme/features/measurement-result.png" width="240" alt="실측 결과 화면"></td>
    <td align="center"><img src="assets/readme/features/detail-capture.png" width="240" alt="제품 상세 촬영 화면"></td>
  </tr>
  <tr>
    <td align="center">실측 촬영</td>
    <td align="center">실측 결과</td>
    <td align="center">제품 상세 촬영</td>
  </tr>
</table>

---

### ✨ AI로 상품 정보 완성하기

사진을 바탕으로 AI가 제품명·브랜드·설명 초안을 생성합니다. 생성된 정보를 확인·수정하고, 가격 등 추가 정보를 직접 입력해 상품 정보를 완성합니다.

<table align="center">
  <tr>
    <td align="center"><img src="assets/readme/features/ai-product-info.png" width="240" alt="AI 제품 정보 생성 버튼 화면"></td>
    <td align="center"><img src="assets/readme/features/product-info-edit.png" width="240" alt="AI 생성 정보 확인·수정 및 추가 정보 입력 화면"></td>
    <td align="center"><img src="assets/readme/features/product-info-complete.png" width="240" alt="상품 정보 완성 화면"></td>
  </tr>
  <tr>
    <td align="center">AI 정보 생성</td>
    <td align="center">정보 확인·입력</td>
    <td align="center">상품 정보 완성</td>
  </tr>
</table>

---

### 📦 업로드하고, 보관하고

완성한 상품을 판매 채널로 전달하고 보관함에서 관리합니다. 진행 중인 작업도 저장한 단계부터 이어갈 수 있습니다.

<table align="center">
  <tr>
    <td align="center"><img src="assets/readme/features/platform-upload.png" width="240" alt="플랫폼별 업로드 및 복사해서 옮기기 화면"></td>
    <td align="center"><img src="assets/readme/features/archive.png" width="240" alt="저장된 상품과 진행 중인 작업을 보여주는 보관함 화면"></td>
  </tr>
  <tr>
    <td align="center">플랫폼 업로드</td>
    <td align="center">보관함</td>
  </tr>
</table>

---

## 🏗 Architecture

착은 **MV(Model–View) 패턴을 기반으로 화면과 데이터를 분리**하고, 촬영·실측·AI 작업과 저장 책임을 별도로 구성했습니다.

![chak 아키텍처: 화면·데이터, 작업 실행, 의존성 주입, 저장 영역의 관계](assets/readme/architecture.svg)

| 설계 방식 | 주요 책임 |
|---|---|
| **MV 패턴** | View: 화면·입력<br/>Model: 상품·측정 데이터와 변경 규칙 |
| **작업 실행 분리** | Workflow·Session: 촬영·실측·AI 작업의 실행과 취소 |
| **의존성 주입** | Protocol: 촬영·인식·AI 기능의 계약<br/>구현체: 실제 기능 또는 테스트용 구현 |
| **저장 분리** | Store·Archive: 상품·사진·실측 기록의 저장과 복원 |

---

## 🛠 Tech Stack

### Core Frameworks

![SwiftUI](https://img.shields.io/badge/SwiftUI-007AFF?style=flat&logo=swift&logoColor=white)
![UIKit](https://img.shields.io/badge/UIKit-2396F3?style=flat&logo=apple&logoColor=white)
![Observation](https://img.shields.io/badge/Observation-5856D6?style=flat&logo=swift&logoColor=white)
![Combine](https://img.shields.io/badge/Combine-FF9500?style=flat&logo=swift&logoColor=white)
![SwiftData](https://img.shields.io/badge/SwiftData-5856D6?style=flat&logo=apple&logoColor=white)

### Camera & Photos

![AVFoundation](https://img.shields.io/badge/AVFoundation-34C759?style=flat&logo=apple&logoColor=white)
![Photos](https://img.shields.io/badge/Photos-FF2D55?style=flat&logo=apple&logoColor=white)
![PhotosUI](https://img.shields.io/badge/PhotosUI-FF9500?style=flat&logo=apple&logoColor=white)

### Vision & Measurement

![Vision](https://img.shields.io/badge/Vision-5856D6?style=flat&logo=apple&logoColor=white)
![Core ML](https://img.shields.io/badge/Core_ML-007AFF?style=flat&logo=apple&logoColor=white)
![ARKit](https://img.shields.io/badge/ARKit-000000?style=flat&logo=apple&logoColor=white)
![LiDAR](https://img.shields.io/badge/LiDAR-34C759?style=flat&logo=apple&logoColor=white)

### Concurrency & Networking

![Swift Concurrency](https://img.shields.io/badge/Swift_Concurrency-F05138?style=flat&logo=swift&logoColor=white)
![URLSession](https://img.shields.io/badge/URLSession-007AFF?style=flat&logo=apple&logoColor=white)

### Interaction & Animation

![AVKit](https://img.shields.io/badge/AVKit-34C759?style=flat&logo=apple&logoColor=white)
![ActivityKit](https://img.shields.io/badge/ActivityKit-FF9500?style=flat&logo=apple&logoColor=white)
![WidgetKit](https://img.shields.io/badge/WidgetKit-007AFF?style=flat&logo=apple&logoColor=white)
![Lottie](https://img.shields.io/badge/Lottie-00BFA5?style=flat)

### Backend

![OpenAI API](https://img.shields.io/badge/OpenAI_API-412991?style=flat)
![Cloudflare Workers](https://img.shields.io/badge/Cloudflare_Workers-F38020?style=flat&logo=cloudflareworkers&logoColor=white)

### Environment

![Swift 6.4](https://img.shields.io/badge/Swift-6.4-F05138?style=flat&logo=swift&logoColor=white&labelColor=F05138)
![Xcode 27.0](https://img.shields.io/badge/Xcode-27.0-147EFB?style=flat&logo=xcode&logoColor=white&labelColor=147EFB)
![Git](https://img.shields.io/badge/Git-F05032?style=flat&logo=git&logoColor=white)
![GitHub](https://img.shields.io/badge/GitHub-181717?style=flat&logo=github&logoColor=white)

<sub>Xcode와 Swift 컴파일러 버전은 현재 로컬 개발 환경 기준입니다.</sub>

### Communication & Design

![Figma](https://img.shields.io/badge/Figma-F24E1E?style=flat&logo=figma&logoColor=white)
![Discord](https://img.shields.io/badge/Discord-5865F2?style=flat&logo=discord&logoColor=white)
![Notion](https://img.shields.io/badge/Notion-000000?style=flat&logo=notion&logoColor=white)
![Miro](https://img.shields.io/badge/Miro-FFD02F?style=flat&logo=miro&logoColor=050038)

---

## 👥 Team

<table width="100%">
  <tr>
    <td width="320" align="center"><img src="assets/readme/mason.png" width="80" alt="이민혁 Mason 프로필"></td>
    <td width="320" align="center"><img src="assets/readme/ddoechii.png" width="80" alt="윤현주 Ddoechii 프로필"></td>
    <td width="320" align="center"><img src="assets/readme/iris.png" width="80" alt="박채은 Iris 프로필"></td>
  </tr>
  <tr>
    <th align="center"><a href="https://github.com/decl5th">이민혁</a></th>
    <th align="center"><a href="https://github.com/qoqoqle">윤현주</a></th>
    <th align="center"><a href="https://github.com/takechaens">박채은</a></th>
  </tr>
  <tr>
    <td align="center">Mason&nbsp;·&nbsp;메&#8288;이&#8288;슨</td>
    <td align="center">Ddoechii&nbsp;·&nbsp;또&#8288;치</td>
    <td align="center">Iris&nbsp;·&nbsp;아&#8288;이&#8288;리&#8288;스</td>
  </tr>
  <tr>
    <td align="center">🎯&nbsp;PM&nbsp;·&nbsp;💻&nbsp;Developer</td>
    <td align="center">🎨&nbsp;Product&nbsp;Designer</td>
    <td align="center">🎨&nbsp;Product&nbsp;Designer</td>
  </tr>
</table>

<table width="100%">
  <tr>
    <td width="320" align="center"><img src="assets/readme/tobae.png" width="80" alt="박지원 Tobae 프로필"></td>
    <td width="320" align="center"><img src="assets/readme/mugu.png" width="80" alt="정무구 Mugu 프로필"></td>
    <td width="320" align="center"><img src="assets/readme/ichi.png" width="80" alt="오하나 Ichi 프로필"></td>
  </tr>
  <tr>
    <th align="center"><a href="https://github.com/tobae-time">박지원</a></th>
    <th align="center"><a href="https://github.com/moogoochung">정무구</a></th>
    <th align="center"><a href="https://github.com/hana5111">오하나</a></th>
  </tr>
  <tr>
    <td align="center">Tobae&nbsp;·&nbsp;토&#8288;바&#8288;에</td>
    <td align="center">Mugu&nbsp;·&nbsp;무&#8288;구</td>
    <td align="center">Ichi&nbsp;·&nbsp;이&#8288;치</td>
  </tr>
  <tr>
    <td align="center">💻&nbsp;Developer</td>
    <td align="center">💻&nbsp;Developer</td>
    <td align="center">💻&nbsp;Developer</td>
  </tr>
</table>

---

## 🔗 Links

[프로젝트 소개](https://developeracademy-postech.github.io/2026-C6-M11-Dobby-Web/) · [고객 지원](https://app.notion.com/p/chak-407b4b9ddf0c802f9886dfa23ab61269?source=copy_link) · [개인정보 처리방침](https://app.notion.com/p/chak-404b4b9ddf0c806aa4f2ce677c724b0b?source=copy_link)

<!-- 시연 영상 URL이 준비되면 링크 추가 -->

<!--
게시 전 확인
- 기능별 화면 이미지 추가
- 공개 빌드의 기능 범위와 기술 스택 대조
- 시연 영상 URL 연결
-->

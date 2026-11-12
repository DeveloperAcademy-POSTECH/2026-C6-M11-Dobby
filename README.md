![착(chak) — 찍고, 재고, 올리는 일을 한 번에 착!](assets/readme/banner.png)

<h1>
  chak(착)&nbsp;
  <a href="https://apps.apple.com/kr/app/chak-%EC%B0%A9/id6823445800"><img src="assets/readme/app-store-badge.svg" height="40" align="center" alt="Download on the App Store"></a>&nbsp;
  <img src="https://img.shields.io/badge/iOS-26.4%2B-000000?style=flat&amp;logo=apple&amp;logoColor=white&amp;labelColor=000000" align="center" alt="iOS 26.4 이상">
  <img src="https://img.shields.io/badge/App-1.0.0-E34825?style=flat&amp;labelColor=E34825" align="center" alt="App 1.0.0">
</h1>

<!-- Apple 공식 다운로드 배지 원본: https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg -->
<!-- 앱 버전 배지는 현재 프로젝트의 MARKETING_VERSION 기준 -->

### 빈티지 의류의 촬영부터 판매 준비까지

착은 빈티지숍 운영자를 위한 iOS 앱입니다.<br>
한 벌의 사진과 실측, 상품 정보를 정리하고 판매 채널로 전달하는 과정을 돕습니다.

---

## ✨ 주요 기능

### 📸 촬영하고, 실측을 확인하고

옷을 펼쳐 촬영하면 사진 위에서 실측 결과를 확인할 수 있습니다. 측정 위치와 치수는 직접 확인하고 수정할 수 있습니다.

<!-- 아래 빈칸에 촬영 / 실측 결과 / 측정점 보정 이미지를 순서대로 삽입 -->

| 촬영 | 실측 결과 | 측정점 보정 |
|:---:|:---:|:---:|
| | | |

---

### ✍️ 사진부터 상품 설명까지

상세 사진을 추가하고 순서를 정리하며 상품 정보를 완성합니다. AI가 만든 제품명·브랜드·설명 초안을 검토하고 수정할 수 있습니다.

<!-- 아래 빈칸에 사진 관리 / AI 생성 / 상품 정보 입력 이미지를 순서대로 삽입 -->

| 상세 사진 | AI 정보 생성 | 상품 정보 |
|:---:|:---:|:---:|
| | | |

---

### 📤 보관하고, 판매 채널로 이어가기

준비 중인 상품은 저장해 이어서 작업하고, 완성한 상품은 보관함에서 관리합니다. 사진과 상품 정보를 채널별 내보내기 흐름으로 전달합니다.

<!-- 아래 빈칸에 보관함 / 상품 상세 / 채널 선택 이미지를 순서대로 삽입 -->

| 보관함 | 상품 상세 | 내보내기 |
|:---:|:---:|:---:|
| | | |

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

<!-- 이름에 프로필 링크를 연결할 때는 <a href="URL">이름</a> 형식 사용 -->

<table width="100%">
  <tr>
    <td width="16%" align="center"><img src="assets/readme/mason.png" width="80" alt="Mason 메이슨 프로필"></td>
    <td width="16%" align="center"><img src="assets/readme/tobae.png" width="80" alt="Tobae 토바에 프로필"></td>
    <td width="16%" align="center"><img src="assets/readme/mugu.png" width="80" alt="Mugu 무구 프로필"></td>
    <td width="16%" align="center"><img src="assets/readme/ichi.png" width="80" alt="Ichi 이치 프로필"></td>
    <td width="16%" align="center"><img src="assets/readme/ddoechii.png" width="80" alt="Ddoechii 또치 프로필"></td>
    <td width="16%" align="center"><img src="assets/readme/iris.png" width="80" alt="Iris 아이리스 프로필"></td>
  </tr>
  <tr>
    <th align="center">Mason</th>
    <th align="center">Tobae</th>
    <th align="center">Mugu</th>
    <th align="center">Ichi</th>
    <th align="center">Ddoechii</th>
    <th align="center">Iris</th>
  </tr>
  <tr>
    <td align="center">메이슨</td>
    <td align="center">토바에</td>
    <td align="center">무구</td>
    <td align="center">이치</td>
    <td align="center">또치</td>
    <td align="center">아이리스</td>
  </tr>
  <tr>
    <td align="center">PM&nbsp;·&nbsp;Developer</td>
    <td align="center">Developer</td>
    <td align="center">Developer</td>
    <td align="center">Developer</td>
    <td align="center">Designer</td>
    <td align="center">Designer</td>
  </tr>
  <tr>
    <td align="center" valign="top"><sub>프로젝트 운영<br>일정·범위 조율<br>상세 촬영</sub></td>
    <td align="center" valign="top"><sub>플랫폼 연동<br>설정</sub></td>
    <td align="center" valign="top"><sub>LiDAR 실측<br>사진 업로드<br>공통 UI</sub></td>
    <td align="center" valign="top"><sub>Garment ML<br>보관함<br>상품 정보 입력</sub></td>
    <td align="center" valign="top"><sub>UX/UI 디자인</sub></td>
    <td align="center" valign="top"><sub>UX/UI 디자인</sub></td>
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
- 팀원 프로필 링크 확인
- 시연 영상 URL 연결
-->

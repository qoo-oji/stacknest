// SPDX-License-Identifier: MIT
// G63 段 4: 参照ファイルの型・対応の宣言・名乗りは、外部ビューアと共有する StackNestViewerKit の Core を使う。
// AppCore を import するモジュール（LibraryServer・App・試験）にも同じ定義を見せるため、ここで再輸出する。
// 依存は Package.swift の AppCore にだけ書き、App/project.yml にはパッケージを足さない（ほかのモジュールは
// StackNestViewerKitCore を直接 import しない）。AppCore の中のファイルは、使うなら自分でも import する。
@_exported import StackNestViewerKitCore

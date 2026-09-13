# zig-pubgrub

[English version](README.md)

パッケージ型とバージョン型にジェネリックな、Zig製の
[PubGrub](https://github.com/dart-lang/pub/tree/main/doc/solver.md)
バージョンソルバです。Dart pubの参照実装を移植しており、単位伝播、
バックジャンプを伴う競合駆動学習、矛盾の導出グラフから生成される
人間が読める競合説明を備えています。

再利用可能な独立ライブラリとして公開しています。

## 特徴

- **決定的な解決** — 同一の入力からは常に同一の選択結果が得られます。
- **競合説明** — 失敗時に、ルート要件から競合まで辿れる説明を生成します
  （例: "Because every version of p2 depends on p1 * which depends on
  p0 <0.1.0, ..."）。
- **ロックファイル優先** — 既存のロックファイルに記録されたバージョンを、
  許される限り優先して選択します。
- **ジェネリック** — ソルバはパッケージ識別子型とバージョン型で
  パラメータ化されており、セマンティックバージョン実装を同梱しています。
- **プロバイダ分離** — パッケージのメタデータ（バージョン一覧、依存関係、
  利用不可マーカー）はユーザー実装のプロバイダ経由で供給されるため、
  レジストリ・ファイルシステム・gitなど任意のソースで動作します。
- **隣接バージョンの圧縮** — 同一の依存関係を共有する連続バージョン列を
  pubの `PackageLister` と同様に単一の依存元範囲へ圧縮します。

## 使い方

`build.zig.zon` の依存としてパッケージを取得し、次のように使います:

```zig
const std = @import("std");
const pubgrub = @import("pubgrub");

const S = pubgrub.SemverSolver;      // Solver(StringPackage, SemanticVersion)
const V = pubgrub.SemanticVersion;

const Provider = struct {
    pub fn listVersions(self: *const Provider, gpa: std.mem.Allocator, pkg: pubgrub.StringPackage) ![]V {
        // pkg の既知バージョンをすべて返す（順不同）。
        // パッケージが存在しない場合は error.PackageNotFound を返す。
    }

    pub fn dependencies(self: *const Provider, gpa: std.mem.Allocator, pkg: pubgrub.StringPackage, version: V) !S.DepResult {
        // .{ .known = deps } または .{ .unavailable = "理由または null" }
    }

    // 省略可: ロックファイルに記録済みのバージョンを優先する。
    pub fn lockedVersion(self: *const Provider, pkg: pubgrub.StringPackage) ?V {
        return null;
    }
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const root_deps = [_]S.Dependency{
        .{ .package = .{ .name = "app" }, .constraint = try pubgrub.parseVersionReq(gpa, "^1.0.0") },
    };

    const provider = Provider{};
    var out = try S.solve(gpa, &provider, .{ .name = "my-project" }, try V.parse("1.0.0"), &root_deps, .{});
    defer out.deinit();

    switch (out.result) {
        .resolved => |r| for (r.selections) |s| {
            std.debug.print("{f} {f}\n", .{ s.package, s.version });
        },
        .failed => |f| std.debug.print("{s}\n", .{f.message}),
    }
}
```

完全に動作するプロバイダの実装例は `examples/resolve_demo.zig` を参照
してください（`zig build example` で実行できます）。

### プロバイダ契約

- `listVersions(gpa, package) ![]V` — 既知の全バージョンを返します。
  `error.PackageNotFound` はハードエラーではなくソルバの競合として
  扱われます。それ以外のエラーは解決処理を中断します。
- `dependencies(gpa, package, version) !DepResult` — `.known` の依存
  エッジ、または `.unavailable`（取り下げ・破損・非互換）と省略可能な
  人間が読める理由を返します。
- `lockedVersion(package) ?V` *（省略可）* — ロックファイルに記録済みの
  バージョン。蓄積された制約が許す限り優先されます。

プロバイダの各メソッドに渡されるアロケータはすべて、解決処理より長く
生存するアリーナです。プロバイダは返却値の裏にあるメモリを解放しては
いけません。

### オプション

- `prefer_oldest` — 条件に合う最も古いバージョンを選びます
  （ダウングレード的な動作）。
- `constraints` — 追加の外部要件: `require` は制約に合うバージョンの
  選択を強制し（そのパッケージが選択対象である場合）、`!require` は
  一致する全バージョンを禁止します。それぞれ失敗レポートにヒントとして
  表示される `reason` を付けられます。

### カスタムのパッケージ型・バージョン型

`Solver(P, V)` はジェネリックです。`P` は `eql`、`hash`、`format` を
提供する必要があります（加えて `lessThan`/`cmp` があると依存関係の順序が
決定的になります）。`V` は `cmp`（全順序）と `format` を提供する必要が
あります（加えて `isPrerelease` があるとプレリリースが優先度を下げられ
ます）。

## バージョン要件

`pubgrub.parseVersionReq` はsemver要件文字列をパースします:

| 構文 | 意味 |
| --- | --- |
| `1.2.3`, `=1.2.3` | 完全一致バージョン |
| `>=1.2.0 <2.0.0` | 比較条件の積（intersection） |
| `1.2`, `1` | パーシャルバージョン（`>=1.2.0 <1.3.0`、`>=1.0.0 <2.0.0`） |
| `*`, `1.x`, `1.2.*` | ワイルドカード |
| `^1.2.3` | 互換範囲（`>=1.2.3 <2.0.0`） |
| `~1.2.3` | パッチレベル範囲（`>=1.2.3 <1.3.0`） |
| `>=1.0.0 <2.0.0 \|\| >=3.0.0` | 和（union） |

プレリリースは暗黙に除外されません。明示的な境界で選択可否を制御します
（常にリリース版より優先度が下がります）。

## テスト

```sh
zig build test       # 単体 + 結合 + ランダム化ブルートフォースオラクル
zig build fmt-check  # zig fmt --check
zig build example    # デモリゾルバを実行
```

オラクルテストはランダム生成した120個の小規模レジストリについて、
ソルバの判定を総当たりの全列挙と比較します。

## ライセンス

MIT

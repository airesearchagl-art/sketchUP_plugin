# frozen_string_literal: true

# su_smart_framing_tools/tools/corner_tool.rb
#
# CornerTool – 交差・未交差を問わずL字コーナーを生成するツール
#
# ■ 状態遷移（ステートマシン）
#   STATE 0: :select_member_a → 1つ目の部材（削除したい側をクリック）
#   STATE 1: :select_member_b → 2つ目の部材（削除したい側をクリック）
#
# ■ 「強制交差＆相互トリム」アルゴリズム（execute_corner）
#
#   交差済み・未交差どちらにも対応するため PushPull フェーズを先行させる:
#
#   ① make_unique: ComponentInstance の場合は固有化して他インスタンスへの影響を防ぐ
#   ② キャッシュ: クリック時点でのカット面のワールド座標（中心・法線）を保存
#   ③ PushPull: 両部材のクリックされた面を 10000mm 押し出して強制的に交差させる
#      （元から交差している場合もさらに延ばすだけなので問題なし）
#   ④ build_half_space_cutter: キャッシュ済みの「元の面位置」を使ってカッターを生成
#      （PushPull 後の現在位置ではなく、クリック時点の面位置で切断する）
#   ⑤ cutter_a.subtract(member_b) / cutter_b.subtract(member_a) で相互トリム
#   ⑥ cleanup_coplanar_edges → commit_operation（失敗時は abort_operation）
#
# ■ 幾何学処理は GeometryHelper に委譲（include SuSmartFramingTools::GeometryHelper）

module SuSmartFramingTools
  class CornerTool
    include GeometryHelper

    # ---- ハイライト色定数 ----------------------------------------
    COLOR_A_HOVER        = Sketchup::Color.new(  0, 120, 255, 180)  # 青（部材A ホバー）
    COLOR_A_CUT_FILL     = Sketchup::Color.new(  0, 120, 255, 100)  # 青半透明（部材A カット面）
    COLOR_A_CUT_EDGE     = Sketchup::Color.new(  0,  80, 220, 230)  # 青（部材A カット輪郭）
    COLOR_B_HOVER        = Sketchup::Color.new(  0, 200,  80, 180)  # 緑（部材B ホバー）
    COLOR_B_CUT_FILL     = Sketchup::Color.new(  0, 200,  80, 100)  # 緑半透明（部材B カット面）
    COLOR_B_CUT_EDGE     = Sketchup::Color.new(  0, 160,  60, 230)  # 緑（部材B カット輪郭）
    COLOR_NON_MANIFOLD   = Sketchup::Color.new(140, 140, 140, 120)  # グレー（非マニフォールド）
    COLOR_BB_WIRE        = Sketchup::Color.new( 80,  80,  80, 160)  # グレー細線（BB 輪郭）

    # ==============================================================
    # Sketchup::Tool コールバック
    # ==============================================================

    def activate
      puts '[CornerTool] activate: ツール起動'
      reset_state
      Sketchup.status_text = status_message
    end

    def deactivate(view)
      puts '[CornerTool] deactivate: ツール終了'
      view.invalidate
    end

    def resume(view)
      Sketchup.status_text = status_message
      view.invalidate
    end

    # ----------------------------------------------------------------
    # onMouseMove: ホバー対象を更新してカット面プレビューを再描画
    # ----------------------------------------------------------------
    def onMouseMove(_flags, x, y, view)
      ph = view.pick_helper
      ph.do_pick(x, y, 5)  # aperture 5px: エッジ/頂点近傍でも確実にピック
      hovered, hovered_tf = pick_solid_with_transform(ph)

      ip = Sketchup::InputPoint.new
      ip.pick(view, x, y)
      @hover_pt = ip.position

      case @state
      when :select_member_a
        @hovered    = hovered
        @hovered_tf = hovered_tf
        @preview_cut_info = if @hovered && manifold?(@hovered)
                              find_cut_face(@hovered, @hover_pt,
                                            cutter_transform: @hovered_tf,
                                            quiet: true)
                            end

      when :select_member_b
        if hovered && hovered != @member_a
          @hovered    = hovered
          @hovered_tf = hovered_tf
          @preview_cut_info = if manifold?(@hovered)
                                find_cut_face(@hovered, @hover_pt,
                                              cutter_transform: @hovered_tf,
                                              quiet: true)
                              end
        else
          @hovered          = nil
          @hovered_tf       = nil
          @preview_cut_info = nil
        end
      end

      view.invalidate
    end

    # ----------------------------------------------------------------
    # onLButtonDown: クリックによる状態遷移
    # ----------------------------------------------------------------
    def onLButtonDown(_flags, x, y, view)
      ph = view.pick_helper
      ph.do_pick(x, y)
      entity, entity_tf = pick_solid_with_transform(ph)

      ip = Sketchup::InputPoint.new
      ip.pick(view, x, y)
      click_pt = ip.position

      case @state
      when :select_member_a
        on_member_a_click(entity, entity_tf, click_pt, view)
      when :select_member_b
        on_member_b_click(entity, entity_tf, click_pt, view)
      end

      Sketchup.status_text = status_message
      view.invalidate
    end

    # ----------------------------------------------------------------
    # onKeyDown: ESC で前の状態に戻る
    # ----------------------------------------------------------------
    def onKeyDown(key, _repeat, _flags, view)
      return unless key == 27  # ESC

      case @state
      when :select_member_a
        puts '[CornerTool] ESC: ツール終了'
        Sketchup.active_model.select_tool(nil)
      when :select_member_b
        puts '[CornerTool] ESC: STATE 0 に戻る（部材A 選択解除）'
        reset_state
        Sketchup.status_text = status_message
        view.invalidate
      end
    end

    # ----------------------------------------------------------------
    # draw: カット平面プレビューの描画
    #
    # STATE 0: ホバー部材のカット面を青で表示
    # STATE 1: 確定済み部材Aのカット面を青で常時表示 + ホバー部材Bのカット面を緑で表示
    # ----------------------------------------------------------------
    def draw(view)
      # STATE 1: 確定済み部材Aのカット平面を常に青で描画
      if @state == :select_member_b && @member_a&.valid? && @cut_info_a
        draw_cut_plane_preview(view, @member_a, @cut_info_a,
                               COLOR_A_CUT_FILL, COLOR_A_CUT_EDGE)
      end

      # ホバー中エンティティのカット面（または BB フォールバック）
      if @hovered&.valid?
        if @preview_cut_info
          fill = @state == :select_member_a ? COLOR_A_CUT_FILL : COLOR_B_CUT_FILL
          edge = @state == :select_member_a ? COLOR_A_CUT_EDGE : COLOR_B_CUT_EDGE
          draw_cut_plane_preview(view, @hovered, @preview_cut_info, fill, edge)
        else
          color = manifold?(@hovered) ? COLOR_A_HOVER : COLOR_NON_MANIFOLD
          draw_highlight(view, @hovered, color, 2)
        end
      end
    end

    # ==============================================================
    # Private
    # ==============================================================
    private

    # ----------------------------------------------------------------
    # STATE 0 クリック処理: 部材Aとカット平面をキャッシュして STATE 1 へ遷移
    # ----------------------------------------------------------------
    def on_member_a_click(entity, entity_tf, click_pt, _view)
      if entity.nil?
        puts '[CornerTool] STATE 0 click: ソリッドが見つかりませんでした（スキップ）'
        return
      end
      unless manifold?(entity)
        Sketchup.status_text = '警告：選択した部材はソリッドではありません。別の部材を選択してください。'
        return
      end

      cut_info = find_cut_face(entity, click_pt, cutter_transform: entity_tf)
      if cut_info.nil?
        Sketchup.status_text = '警告：小口面を検出できませんでした。部材の小口（先端の面）をクリックしてください。'
        return
      end

      puts "[CornerTool] STATE 0 click: 部材A を登録 → #{entity_label(entity)}"
      @member_a    = entity
      @member_a_tf = entity_tf
      @click_pt_a  = click_pt
      @cut_info_a  = cut_info   # ワールド座標でキャッシュ（execute_corner で使用）
      @hovered     = nil
      @hovered_tf  = nil
      @preview_cut_info = nil
      @state = :select_member_b
      puts '[CornerTool] → STATE 1 に遷移'
    end

    # ----------------------------------------------------------------
    # STATE 1 クリック処理: 部材Bを確定してコーナー処理を実行
    # ----------------------------------------------------------------
    def on_member_b_click(entity, entity_tf, click_pt, view)
      if entity.nil?
        puts '[CornerTool] STATE 1 click: ソリッドが見つかりませんでした（スキップ）'
        return
      end
      if entity == @member_a
        Sketchup.status_text = '警告：部材Aと同じ部材です。別の部材を選択してください。'
        return
      end
      unless manifold?(entity)
        Sketchup.status_text = '警告：選択した部材はソリッドではありません。別の部材を選択してください。'
        return
      end

      cut_info_b = find_cut_face(entity, click_pt, cutter_transform: entity_tf)
      if cut_info_b.nil?
        Sketchup.status_text = '警告：小口面を検出できませんでした。部材の小口（先端の面）をクリックしてください。'
        return
      end

      puts "[CornerTool] STATE 1 click: 部材B を確定 → #{entity_label(entity)}"
      execute_corner(@member_a, @member_a_tf, @click_pt_a, @cut_info_a,
                     entity, entity_tf, click_pt, cut_info_b,
                     view)
    end

    # ----------------------------------------------------------------
    # 原子操作フローによるコーナー処理（execute_corner）
    #
    # 設計原則:
    #   - 幾何データ（center/normal）は処理冒頭で純粋な数値として退避。
    #     以降の Entity 削除・再編成の影響を受けない。
    #   - make_unique → face 再取得 → pushpull を 1 部材ずつ原子的に実行。
    #   - cutter の生成と subtract を逐次実行し、
    #     「subtract 結果で変数を上書き」することで古い参照を確実に破棄。
    #   - 2 本目の cutter は 1 本目の subtract 完了後に生成することで
    #     SketchUp 内部の Entity 再編成による参照破壊を回避する。
    #   - waste_pt は元の法線方向に固定し、build_half_space_cutter の
    #     内積チェックを常に正値に保証する。
    # ----------------------------------------------------------------
    def execute_corner(member_a, member_a_tf, click_pt_a, cut_info_a,
                       member_b, member_b_tf, click_pt_b, cut_info_b,
                       view)
      model = Sketchup.active_model

      # ──────────────────────────────────────────────────────────────
      # 事前バリデーション: 両部材がソリッドであることを確認
      # subtract はソリッドでない場合に nil を返すため、ここで早期ガードする
      # ──────────────────────────────────────────────────────────────
      unless manifold?(member_a)
        UI.messagebox("部材Aがソリッドグループではありません。\nソリッドグループ/コンポーネントを選択してください。", MB_OK)
        return
      end
      unless manifold?(member_b)
        UI.messagebox("部材Bがソリッドグループではありません。\nソリッドグループ/コンポーネントを選択してください。", MB_OK)
        return
      end

      # ──────────────────────────────────────────────────────────────
      # ① 幾何データの完全退避（Entity 参照に依存しない純粋な数値）
      # ──────────────────────────────────────────────────────────────
      a_pt = cut_info_a[:center].clone   # 部材A クリック面の中心（ワールド座標）
      a_n  = cut_info_a[:normal].clone   # 部材A クリック面の法線（外向き、正規化済み）
      b_pt = cut_info_b[:center].clone
      b_n  = cut_info_b[:normal].clone

      # waste_pt: 元の法線方向に 5000mm 固定オフセット（部材が大きい場合でも体内に留まらない距離）
      # → build_half_space_cutter 内 dot = n.dot(waste_pt - pt) = n.dot(n*5000) = 5000 > 0 を保証
      waste_pt_a = a_pt.offset(a_n, 5000.mm)   # cutter_a（B を削る刃）の方向基準点
      waste_pt_b = b_pt.offset(b_n, 5000.mm)   # cutter_b（A を削る刃）の方向基準点

      # PushPull 距離: |t値| + 1000mm（確実に相手平面を突き抜ける量）
      diag_a        = member_a.bounds.min.distance(member_a.bounds.max)
      diag_b        = member_b.bounds.min.distance(member_b.bounds.max)
      fallback_dist = [diag_a, diag_b].max * 2 + 1000.mm

      denom = b_n.dot(a_n)
      if denom.abs >= 1e-6
        push_a = (-b_n.dot(a_pt - b_pt) / denom).abs + 1000.mm
        push_b = (-a_n.dot(b_pt - a_pt) / denom).abs + 1000.mm
      else
        push_a = fallback_dist
        push_b = fallback_dist
      end

      model.start_operation('Corner Solid', true)
      cutter = nil   # 生成中のカッター参照（rescue で erase! するためのホルダー）

      begin
        # ──────────────────────────────────────────────────────────
        # ② Atomic Step 1: 部材A — make_unique → face 再取得 → PushPull
        # ──────────────────────────────────────────────────────────
        member_a.make_unique if member_a.is_a?(Sketchup::ComponentInstance)
        face_a = find_cut_face_object(member_a, click_pt_a, entity_transform: member_a_tf)
        raise '部材Aの小口面を取得できませんでした。小口（先端の面）をクリックしてください。' if face_a.nil?
        face_a.pushpull(push_a)
        # face_a は pushpull 後に無効化されるが以降は使用しない
        puts "[CornerTool] PushPull A 完了: #{push_a.to_f.round(1)}in"

        # ──────────────────────────────────────────────────────────
        # Atomic Step 2: 部材B — make_unique → face 再取得 → PushPull
        # ──────────────────────────────────────────────────────────
        member_b.make_unique if member_b.is_a?(Sketchup::ComponentInstance)
        face_b = find_cut_face_object(member_b, click_pt_b, entity_transform: member_b_tf)
        raise '部材Bの小口面を取得できませんでした。小口（先端の面）をクリックしてください。' if face_b.nil?
        face_b.pushpull(push_b)
        puts "[CornerTool] PushPull B 完了: #{push_b.to_f.round(1)}in"

        # ──────────────────────────────────────────────────────────
        # Atomic Step 3: cutter_a 生成 → member_b をトリム → 参照を更新
        # （cutter 生成 & subtract を一組で実行し古い参照を即座に破棄）
        # ──────────────────────────────────────────────────────────
        cutter = build_half_space_cutter(model, a_pt, a_n, member_b, waste_pt_a)
        raise 'カッターA（部材B 用）の生成に失敗しました' if cutter.nil?

        puts '[CornerTool] cutter_a.subtract(member_b) 実行中...'
        res_b  = cutter.subtract(member_b)     # 戻り値を明示的に受け取る
        cutter = nil
        raise 'ブーリアン演算（部材B のトリム）が失敗しました' if res_b.nil?
        member_b = res_b
        raise '部材B のトリム結果が無効です' unless member_b.valid?

        # ── 部材A が 1 本目の subtract 後もまだ有効なソリッドか確認 ────
        # SketchUp の内部 Entity 再編成で参照が壊れていた場合は即時中断する
        unless member_a.valid? && manifold?(member_a)
          raise '部材Aが1本目のトリム後に無効化されました。' \
                '部材が正しいソリッドグループか確認してください。'
        end

        # ──────────────────────────────────────────────────────────
        # Atomic Step 4: cutter_b 生成 → member_a をトリム → 参照を更新
        # Step 3 の subtract 完了後に生成することで
        # SketchUp 内部の Entity 再編成による参照破壊を防ぐ
        # ──────────────────────────────────────────────────────────
        cutter = build_half_space_cutter(model, b_pt, b_n, member_a, waste_pt_b)
        raise 'カッターB（部材A 用）の生成に失敗しました' if cutter.nil?

        puts '[CornerTool] cutter_b.subtract(member_a) 実行中...'
        res_a  = cutter.subtract(member_a)     # 戻り値を明示的に受け取る
        cutter = nil
        raise 'ブーリアン演算（部材A のトリム）が失敗しました' if res_a.nil?
        member_a = res_a
        raise '部材A のトリム結果が無効です' unless member_a.valid?

        # ──────────────────────────────────────────────────────────
        # ③ 共面エッジのクリーンアップ & コミット
        # ──────────────────────────────────────────────────────────
        cleanup_coplanar_edges(member_a)
        cleanup_coplanar_edges(member_b)

        model.commit_operation
        puts "[CornerTool] 完了: #{entity_label(member_a)} / #{entity_label(member_b)}"
        Sketchup.status_text = 'コーナー処理完了。ESC で次の部材Aを選択できます。'
        reset_state

      rescue StandardError => e
        model.abort_operation
        cutter&.erase! if cutter&.valid?
        puts "[CornerTool] execute_corner エラー: #{e.class}: #{e.message}"
        UI.messagebox("コーナー処理失敗：\n#{e.message}", MB_OK)
      end

      view.invalidate
    end

    # ----------------------------------------------------------------
    # カット平面プレビュー描画（BB グレー細線 + カット面ポリゴン）
    # ----------------------------------------------------------------
    def draw_cut_plane_preview(view, entity, cut_info, fill_color, edge_color)
      return unless entity&.valid?

      draw_highlight(view, entity, COLOR_BB_WIRE, 1)

      center    = cut_info[:center]
      normal    = cut_info[:normal]
      half_size = entity.bounds.min.distance(entity.bounds.max) * 0.7

      axes  = normal.axes
      perp1 = axes[0]; perp1.length = half_size
      perp2 = axes[1]; perp2.length = half_size

      pts = [
        center.offset(perp1).offset(perp2),
        center.offset(perp1.reverse).offset(perp2),
        center.offset(perp1.reverse).offset(perp2.reverse),
        center.offset(perp1).offset(perp2.reverse),
      ]

      view.drawing_color = fill_color
      view.draw(GL_POLYGON, pts)

      view.line_width    = 2
      view.drawing_color = edge_color
      view.draw(GL_LINES, [pts[0], pts[1], pts[1], pts[2],
                            pts[2], pts[3], pts[3], pts[0]])
    end

    # ----------------------------------------------------------------
    # 状態リセット（STATE 0 の初期状態に戻す）
    # ----------------------------------------------------------------
    def reset_state
      @state            = :select_member_a
      @member_a         = nil
      @member_a_tf      = nil
      @click_pt_a       = nil
      @cut_info_a       = nil
      @hovered          = nil
      @hovered_tf       = nil
      @hover_pt         = nil
      @preview_cut_info = nil
    end

    # ----------------------------------------------------------------
    # ステートに対応したステータスバーメッセージ
    # ----------------------------------------------------------------
    def status_message
      case @state
      when :select_member_a
        '【包絡】1. 1つ目の部材の小口（先端の面）をクリックしてください'
      when :select_member_b
        '【包絡】2. 2つ目の部材の小口（先端の面）をクリックしてください（ESC で部材A 再選択）'
      else
        '処理中...'
      end
    end
  end
end

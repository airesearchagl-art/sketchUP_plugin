# frozen_string_literal: true

# su_smart_framing_tools/tools/split_tool.rb
#
# SplitTool – 境界ソリッドを使ってターゲットを 2 つの独立したソリッドに分割するツール
#
# ■ 状態遷移（ステートマシン）
#   STATE 0: :cutter_selection       → カット境界ソリッド（柱など）を選択
#   STATE 1: :split_target_selection → 分割対象ソリッドの任意の点をクリック
#
# ■ 分割アルゴリズム（execute_split）
#   SketchUp に単一の split API は存在しないため、ハーフスペースカッター法を
#   両側に適用することで 2 分割を実現する。
#
#   1. target を同位置に複製 → target_dup
#   2. カット平面の +法線側を削るハーフスペース（half_space_plus）を生成
#   3. カット平面の −法線側を削るハーフスペース（half_space_minus）を生成
#   4. half_space_plus.subtract(target)     → res1（−法線側の残存部）
#   5. half_space_minus.subtract(target_dup) → res2（+法線側の残存部）
#   6. cleanup_coplanar_edges(res1), cleanup_coplanar_edges(res2)
#   7. commit_operation（失敗時は abort_operation で全ロールバック）
#
# ■ 幾何学処理は GeometryHelper に委譲（include SuSmartFramingTools::GeometryHelper）
#   - pick_solid_with_transform / find_cut_face / build_half_space_cutter
#   - cleanup_coplanar_edges / manifold? / bounding_boxes_intersect?
#   - draw_highlight / entity_label

module SuSmartFramingTools
  class SplitTool
    include GeometryHelper

    # ---- ハイライト色定数 ----------------------------------------
    COLOR_CUTTER_HOVER    = Sketchup::Color.new(  0, 210, 255, 180)  # シアン（STATE 0 ホバー）
    COLOR_CUTTER_SELECTED = Sketchup::Color.new(  0, 210, 255, 230)  # シアン（STATE 1 固定）
    COLOR_TARGET_VALID    = Sketchup::Color.new(255, 140,   0, 180)  # オレンジ（交差あり）
    COLOR_TARGET_INVALID  = Sketchup::Color.new(160,   0, 200, 180)  # 紫（交差なし）
    COLOR_NON_MANIFOLD    = Sketchup::Color.new(140, 140, 140, 120)  # グレー（非マニフォールド）
    COLOR_BB_PREVIEW      = Sketchup::Color.new( 80,  80,  80, 160)  # グレー細線（BB プレビュー）
    COLOR_CUT_PLANE_FILL  = Sketchup::Color.new(255,   0,   0, 100)  # 半透明赤（カット境界面）
    COLOR_CUT_PLANE_EDGE  = Sketchup::Color.new(220,  30,  30, 220)  # 赤（カット境界面アウトライン）

    # ==============================================================
    # Sketchup::Tool コールバック
    # ==============================================================

    def activate
      puts '[SplitTool] activate: ツール起動'
      reset_state

      # 起動時に有効なソリッドが 1 つだけ選択されていれば自動的にカッターとして登録し STATE 1 へ
      sel = Sketchup.active_model.selection
      if sel.length == 1
        candidate = sel.first
        if (candidate.is_a?(Sketchup::Group) || candidate.is_a?(Sketchup::ComponentInstance)) &&
           manifold?(candidate)
          puts "[SplitTool] activate: 選択済みソリッドをカッターとして自動登録 → #{entity_label(candidate)}"
          @cutter                  = candidate
          @cutter_global_transform = candidate.transformation
          @state                   = :split_target_selection
          sel.clear
        end
      end

      Sketchup.status_text = status_message
    end

    def deactivate(view)
      puts '[SplitTool] deactivate: ツール終了'
      view.invalidate
    end

    def resume(view)
      Sketchup.status_text = status_message
      view.invalidate
    end

    # ----------------------------------------------------------------
    # onMouseMove: ホバー対象を更新してハイライトを再描画
    # STATE 1 では hover_pt を取得し、カット平面プレビュー用の cut_info を事前計算する
    # ----------------------------------------------------------------
    def onMouseMove(_flags, x, y, view)
      ph = view.pick_helper
      ph.do_pick(x, y)
      hovered, = pick_solid_with_transform(ph)

      case @state
      when :cutter_selection
        @hovered = hovered
        puts "[SplitTool] STATE 0 hover: #{entity_label(@hovered)}" if @hovered

      when :split_target_selection
        ip = Sketchup::InputPoint.new
        ip.pick(view, x, y)
        @hover_pt = ip.position

        if hovered && hovered != @cutter
          @hovered            = hovered
          @hovered_intersects = bounding_boxes_intersect?(@cutter, @hovered)
          # カット平面を事前計算（quiet モードで puts スパムを抑制）
          @preview_cut_info = if @hovered_intersects && manifold?(@hovered)
                                find_cut_face(@cutter, @hover_pt,
                                              cutter_transform: @cutter_global_transform,
                                              quiet: true)
                              end
          puts "[SplitTool] STATE 1 hover: #{entity_label(@hovered)} " \
               "intersects=#{@hovered_intersects} preview=#{!@preview_cut_info.nil?}"
        else
          @hovered            = nil
          @hovered_intersects = false
          @preview_cut_info   = nil
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
      entity, entity_transform = pick_solid_with_transform(ph)

      case @state
      when :cutter_selection
        on_cutter_click(entity, entity_transform, view)

      when :split_target_selection
        ip = Sketchup::InputPoint.new
        ip.pick(view, x, y)
        click_pt = ip.position
        puts "[SplitTool] STATE 1 click_pt=#{click_pt}"
        on_split_target_click(entity, click_pt, view)
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
      when :cutter_selection
        puts '[SplitTool] ESC: ツール終了'
        Sketchup.active_model.select_tool(nil)

      when :split_target_selection
        puts '[SplitTool] ESC: STATE 0 に戻る（カッター選択解除）'
        reset_state
        Sketchup.status_text = status_message
        view.invalidate
      end
    end

    # ----------------------------------------------------------------
    # draw: ハイライト＆カット平面プレビュー描画
    #
    # SplitTool では「どちら側が削れるか」は問わないため、
    # ターゲット BB はグレー細線で表示し、カット位置を赤ポリゴン（刃）のみで表現する。
    # ※ draw コールバック内でのみ有効
    # ----------------------------------------------------------------
    def draw(view)
      draw_highlight(view, @cutter, COLOR_CUTTER_SELECTED, 3) if @cutter

      if @hovered
        if @state == :split_target_selection && @hovered_intersects && @preview_cut_info
          # カット平面プレビュー: BB はグレー細線 + 赤いカット面ポリゴン（刃）
          draw_cut_plane_preview(view, @hovered, @preview_cut_info)
        else
          draw_highlight(view, @hovered, hovered_color, 2)
        end
      end
    end

    # ==============================================================
    # Private
    # ==============================================================
    private

    # ----------------------------------------------------------------
    # STATE 0 クリック処理: カッターを選択して STATE 1 へ遷移
    # ----------------------------------------------------------------
    def on_cutter_click(entity, entity_transform, _view)
      if entity.nil?
        puts '[SplitTool] STATE 0 click: ソリッドに当たりませんでした（スキップ）'
        return
      end

      unless manifold?(entity)
        puts "[SplitTool] STATE 0 click: 非マニフォールド → 選択不可 #{entity_label(entity)}"
        Sketchup.status_text = '警告：選択した部材はソリッドではありません。別の部材を選択してください。'
        return
      end

      puts "[SplitTool] STATE 0 click: カッター選択 → #{entity_label(entity)}"
      @cutter                  = entity
      @cutter_global_transform = entity_transform || entity.transformation
      @hovered                 = nil
      @state                   = :split_target_selection
      puts '[SplitTool] → STATE 1 に遷移'
    end

    # ----------------------------------------------------------------
    # STATE 1 クリック処理: 分割対象とクリック点を受け取りブーリアン演算を実行
    # ----------------------------------------------------------------
    def on_split_target_click(entity, click_pt, view)
      if entity.nil?
        puts '[SplitTool] STATE 1 click: ソリッドに当たりませんでした（スキップ）'
        return
      end

      if entity == @cutter
        puts '[SplitTool] STATE 1 click: カッター自身をクリック（スキップ）'
        return
      end

      unless manifold?(entity)
        puts "[SplitTool] STATE 1 click: 非マニフォールド → 操作不可 #{entity_label(entity)}"
        Sketchup.status_text = '警告：分割対象がソリッドではありません。'
        return
      end

      unless bounding_boxes_intersect?(@cutter, entity)
        puts '[SplitTool] STATE 1 click: カッターと対象が交差していません（スキップ）'
        Sketchup.status_text = '警告：カッターと対象部材が交差していません。別の箇所を選択してください。'
        return
      end

      puts "[SplitTool] STATE 1 click: スプリット実行 target=#{entity_label(entity)}"
      execute_split(entity, @cutter, click_pt, view)
    end

    # ----------------------------------------------------------------
    # ブーリアン演算による 2 分割（execute_split）
    #
    # カット平面に対して正逆 2 つのハーフスペースを生成し、
    # ターゲットとその複製にそれぞれ subtract を行うことで
    # 独立した 2 つのソリッドを生成する。
    #
    # ★ half_space_minus 用 opp_click_pt について:
    #   build_half_space_cutter は dot = plane_n.dot(click_pt - plane_pt) が
    #   負の場合に plane_n.reverse! で法線を反転する。
    #   逆向き法線（n_rev）を渡す際に click_pt がそのまま元のクリック点だと
    #   dot < 0 となって安全弁が誤作動し、n_rev が再反転されてしまう。
    #   これを防ぐため、n_rev 方向にオフセットした opp_click_pt を合成する。
    #
    # ★ Undo 設計:
    #   すべての操作を 1 つの start_operation にまとめる。
    #   失敗時の abort_operation が target_dup・half_space 群の生成と
    #   subtract 結果をすべて自動ロールバックする。
    # ----------------------------------------------------------------
    def execute_split(target, cutter, click_pt, view)
      model = Sketchup.active_model

      # ---- Step 1: カット平面の特定 --------------------------------
      cut_info = find_cut_face(cutter, click_pt, cutter_transform: @cutter_global_transform)
      if cut_info.nil?
        puts '[SplitTool] execute_split: カット平面が見つかりませんでした'
        UI.messagebox(
          "カット平面を検出できませんでした。\n" \
          "・カッター（境界ソリッド）と分割対象が正しく交差しているか確認してください\n" \
          "・クリック位置を変えて再試行してください",
          MB_OK
        )
        return
      end
      puts "[SplitTool] execute_split: カット平面検出 " \
           "center=#{cut_info[:center].to_s.gsub("\n", '')} " \
           "dot=#{cut_info[:dot].round(4)}"

      # ---- Step 2〜7: Undo ラップ → 複製 → 2 ハーフスペース → subtract × 2 → cleanup ----
      model.start_operation('Split Solid', true)
      target_dup       = nil
      half_space_plus  = nil
      half_space_minus = nil

      begin
        # ターゲットを同位置に複製（もう一方の分割片として使用）
        target_dup = target.copy
        raise 'ターゲットの複製に失敗しました' unless target_dup&.valid?

        # 法線ベクトルを独立したオブジェクトとして用意
        # build_half_space_cutter は plane_n を reverse! で変更する場合があるため、
        # 各呼び出しに対して別オブジェクトを渡す
        n_fwd = cut_info[:normal]          # 正方向: find_cut_face で dot > 0 が保証されている
        n_rev = cut_info[:normal].reverse  # 逆方向: .reverse は新しいベクトルオブジェクトを返す

        # half_space_minus 用の合成 click_pt: n_rev 方向に十分離れた点を生成
        # dot = n_rev.dot(opp_click_pt - center) > 0 を保証して安全弁の誤作動を防ぐ
        target_diag  = target.bounds.min.distance(target.bounds.max)
        opp_dist     = [target_diag * 1.5, 1.0.m].max
        opp_click_pt = cut_info[:center].offset(n_rev, opp_dist)

        # half_space_plus: +法線側（クリックした側）を削るカッター
        half_space_plus = build_half_space_cutter(
          model,
          cut_info[:center],
          n_fwd,
          target,
          click_pt
        )
        raise 'ハーフスペース（+）の生成に失敗しました' if half_space_plus.nil?

        # half_space_minus: −法線側（反対側）を削るカッター（target_dup 用）
        half_space_minus = build_half_space_cutter(
          model,
          cut_info[:center],
          n_rev,
          target_dup,
          opp_click_pt
        )
        raise 'ハーフスペース（−）の生成に失敗しました' if half_space_minus.nil?

        # ---- subtract 実行 ----------------------------------------
        puts '[SplitTool] execute_split: half_space_plus.subtract(target) 実行中...'
        res1            = half_space_plus.subtract(target)
        half_space_plus = nil  # subtract 成功時は API が cutter を自動削除済み
        raise 'ブーリアン演算（res1: +法線側）が失敗しました（ソリッドが非マニフォールドの可能性があります）' if res1.nil?

        puts '[SplitTool] execute_split: half_space_minus.subtract(target_dup) 実行中...'
        res2             = half_space_minus.subtract(target_dup)
        half_space_minus = nil  # subtract 成功時は API が cutter を自動削除済み
        target_dup       = nil  # subtract で target_dup は res2 に変化（参照を nil 化）
        raise 'ブーリアン演算（res2: −法線側）が失敗しました（ソリッドが非マニフォールドの可能性があります）' if res2.nil?

        # ---- 断面の共面エッジをクリーンアップ ----------------------
        cleanup_coplanar_edges(res1)
        cleanup_coplanar_edges(res2)

        model.commit_operation
        puts "[SplitTool] execute_split: 完了 " \
             "res1=#{entity_label(res1)} res2=#{entity_label(res2)}"

        # STATE 1 を維持して同じカッターで連続スプリットを可能にする
        @hovered            = nil
        @hovered_intersects = false
        @preview_cut_info   = nil
        @hover_pt           = nil
        Sketchup.status_text = 'スプリット完了。引き続き同じカッターで別の部材を分割できます。ESC でカッター再選択。'

      rescue RuntimeError => e
        # abort_operation により start_operation 以降のすべての変更をロールバック:
        #   - target_dup の生成取り消し
        #   - half_space_plus / half_space_minus の生成取り消し
        #   - subtract 済みの res1 があれば取り消し（target が元に戻る）
        model.abort_operation
        half_space_plus  = nil
        half_space_minus = nil
        target_dup       = nil
        puts "[SplitTool] execute_split エラー: #{e.message}"
        UI.messagebox("スプリット失敗：\n#{e.message}", MB_OK)
      end

      view.invalidate
    end

    # ----------------------------------------------------------------
    # カット平面プレビュー描画
    #
    # SplitTool は「両側に切れる」ため削除側の色分けは不要。
    # BB はグレー細線で形状を示し、カット位置だけを半透明赤ポリゴンで可視化する。
    # （draw_highlight は GeometryHelper から継承）
    # ----------------------------------------------------------------
    def draw_cut_plane_preview(view, entity, cut_info)
      return unless entity&.valid?

      # ① ターゲット BB をグレー細線で描画（形状把握のみ）
      draw_highlight(view, entity, COLOR_BB_PREVIEW, 1)

      # ② カット平面ポリゴンの頂点を算出
      center    = cut_info[:center]
      normal    = cut_info[:normal]
      bb        = entity.bounds
      half_size = bb.min.distance(bb.max) * 0.7

      axes  = normal.axes
      perp1 = axes[0]; perp1.length = half_size
      perp2 = axes[1]; perp2.length = half_size

      pts = [
        center.offset(perp1).offset(perp2),
        center.offset(perp1.reverse).offset(perp2),
        center.offset(perp1.reverse).offset(perp2.reverse),
        center.offset(perp1).offset(perp2.reverse),
      ]

      # ③ 半透明赤ポリゴン（カット境界面の刃）
      view.drawing_color = COLOR_CUT_PLANE_FILL
      view.draw(GL_POLYGON, pts)

      # ④ 不透明赤アウトライン（境界面の縁取り）
      view.line_width    = 2
      view.drawing_color = COLOR_CUT_PLANE_EDGE
      view.draw(GL_LINES, [pts[0], pts[1], pts[1], pts[2], pts[2], pts[3], pts[3], pts[0]])
    end

    def hovered_color
      return COLOR_NON_MANIFOLD unless @hovered && manifold?(@hovered)

      case @state
      when :cutter_selection
        COLOR_CUTTER_HOVER
      when :split_target_selection
        @hovered_intersects ? COLOR_TARGET_VALID : COLOR_TARGET_INVALID
      else
        COLOR_TARGET_VALID
      end
    end

    # ----------------------------------------------------------------
    # 状態リセット（STATE 0 の初期状態に戻す）
    # ----------------------------------------------------------------
    def reset_state
      @state                   = :cutter_selection
      @cutter                  = nil
      @cutter_global_transform = nil
      @hovered                 = nil
      @hovered_intersects      = false
      @hover_pt                = nil
      @preview_cut_info        = nil
    end

    # ----------------------------------------------------------------
    # ステートに対応したステータスバーメッセージ
    # ----------------------------------------------------------------
    def status_message
      case @state
      when :cutter_selection
        '【スプリット】1. カットの基準となる境界ソリッド（柱など）をクリックしてください'
      when :split_target_selection
        '【スプリット】2. 2つに分割したいソリッドをクリックしてください'
      else
        '処理中...'
      end
    end
  end
end

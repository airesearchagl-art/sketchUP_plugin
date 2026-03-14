# frozen_string_literal: true

# su_smart_framing_tools/tools/trim_tool.rb
#
# TrimTool – 交差ソリッドのトリムツール（ハーフスペースカッター法）
#
# ■ 状態遷移（ステートマシン）
#   STATE 0: :cutter_selection
#     ユーザーがカット境界となるソリッド（柱など）をクリック → STATE 1 へ
#
#   STATE 1: :trim_target_selection
#     ユーザーが切り落とす側の端部をクリック → ブーリアン演算 → STATE 1 維持
#     （同じカッターで連続トリム可能。ESC で STATE 0 へ戻る）
#
# ■ 幾何学処理は GeometryHelper に委譲（include SuSmartFramingTools::GeometryHelper）
#   - pick_solid_with_transform / find_cut_face / build_half_space_cutter
#   - cleanup_coplanar_edges / manifold? / bounding_boxes_intersect?
#   - draw_highlight / entity_label

module SuSmartFramingTools
  class TrimTool
    include GeometryHelper

    # ---- ハイライト色定数 ----------------------------------------
    COLOR_CUTTER_HOVER    = Sketchup::Color.new(  0, 210, 255, 180)  # シアン（STATE 0 ホバー）
    COLOR_CUTTER_SELECTED = Sketchup::Color.new(  0, 210, 255, 230)  # シアン（STATE 1 固定）
    COLOR_TARGET_VALID    = Sketchup::Color.new(255, 140,   0, 180)  # オレンジ（保持側 / 交差あり）
    COLOR_TARGET_INVALID  = Sketchup::Color.new(160,   0, 200, 180)  # 紫（交差なし）
    COLOR_NON_MANIFOLD    = Sketchup::Color.new(140, 140, 140, 120)  # グレー（非マニフォールド）
    COLOR_BB_PREVIEW      = Sketchup::Color.new( 80,  80,  80, 160)  # グレー細線（カット面プレビュー時の BB）
    COLOR_CUT_PLANE_FILL  = Sketchup::Color.new(255,   0,   0, 100)  # 半透明赤（カット境界面ポリゴン）
    COLOR_CUT_PLANE_EDGE  = Sketchup::Color.new(220,  30,  30, 220)  # 赤（カット境界面アウトライン）

    # ==============================================================
    # Sketchup::Tool コールバック
    # ==============================================================

    def activate
      puts '[TrimTool] activate: ツール起動'
      reset_state

      # 起動時に有効なソリッドが1つだけ選択されていれば自動的にカッターとして登録し STATE 1 へ
      sel = Sketchup.active_model.selection
      if sel.length == 1
        candidate = sel.first
        if (candidate.is_a?(Sketchup::Group) || candidate.is_a?(Sketchup::ComponentInstance)) &&
           manifold?(candidate)
          puts "[TrimTool] activate: 選択済みソリッドをカッターとして自動登録 → #{entity_label(candidate)}"
          @cutter                  = candidate
          @cutter_global_transform = candidate.transformation  # 選択エンティティはトップレベルと想定
          @state                   = :trim_target_selection
          sel.clear
        end
      end

      Sketchup.status_text = status_message
    end

    def deactivate(view)
      puts '[TrimTool] deactivate: ツール終了'
      view.invalidate
    end

    def resume(view)
      Sketchup.status_text = status_message
      view.invalidate
    end

    # ----------------------------------------------------------------
    # onMouseMove: ホバー対象を更新してハイライトを再描画
    # STATE 1 では hover_pt を取得し、削除プレビュー用の cut_info を事前計算する
    # ----------------------------------------------------------------
    def onMouseMove(_flags, x, y, view)
      ph = view.pick_helper
      ph.do_pick(x, y)
      hovered, = pick_solid_with_transform(ph)

      case @state
      when :cutter_selection
        @hovered = hovered
        puts "[TrimTool] STATE 0 hover: #{entity_label(@hovered)}" if @hovered

      when :trim_target_selection
        ip = Sketchup::InputPoint.new
        ip.pick(view, x, y)
        @hover_pt = ip.position

        if hovered && hovered != @cutter
          @hovered            = hovered
          @hovered_intersects = bounding_boxes_intersect?(@cutter, @hovered)
          @preview_cut_info   = if @hovered_intersects && manifold?(@hovered)
                                  find_cut_face(@cutter, @hover_pt,
                                                cutter_transform: @cutter_global_transform,
                                                quiet: true)
                                end
          puts "[TrimTool] STATE 1 hover: #{entity_label(@hovered)} " \
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

      when :trim_target_selection
        ip = Sketchup::InputPoint.new
        ip.pick(view, x, y)
        click_pt = ip.position
        puts "[TrimTool] STATE 1 click_pt=#{click_pt}"
        on_trim_target_click(entity, click_pt, view)
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
        puts '[TrimTool] ESC: ツール終了'
        Sketchup.active_model.select_tool(nil)

      when :trim_target_selection
        puts '[TrimTool] ESC: STATE 0 に戻る（カッター選択解除）'
        reset_state
        Sketchup.status_text = status_message
        view.invalidate
      end
    end

    # ----------------------------------------------------------------
    # draw: ハイライト＆カット平面プレビュー描画
    #
    # STATE 1 でターゲット候補にホバー中かつ preview_cut_info がある場合は、
    # draw_cut_plane_preview により「どこで切れるか」を半透明赤ポリゴンで可視化する。
    # ※ draw コールバック内でのみ有効
    # ----------------------------------------------------------------
    def draw(view)
      draw_highlight(view, @cutter, COLOR_CUTTER_SELECTED, 3) if @cutter

      if @hovered
        if @state == :trim_target_selection && @hovered_intersects && @preview_cut_info
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
        puts '[TrimTool] STATE 0 click: ソリッドに当たりませんでした（スキップ）'
        return
      end

      unless manifold?(entity)
        puts "[TrimTool] STATE 0 click: 非マニフォールド → 選択不可 #{entity_label(entity)}"
        Sketchup.status_text = '警告：選択した部材はソリッドではありません。別の部材を選択してください。'
        return
      end

      puts "[TrimTool] STATE 0 click: カッター選択 → #{entity_label(entity)}"
      @cutter                  = entity
      @cutter_global_transform = entity_transform || entity.transformation
      @hovered                 = nil
      @state                   = :trim_target_selection
      puts '[TrimTool] → STATE 1 に遷移'
    end

    # ----------------------------------------------------------------
    # STATE 1 クリック処理: トリム対象とクリック点を受け取りブーリアン演算を実行
    # ----------------------------------------------------------------
    def on_trim_target_click(entity, click_pt, view)
      if entity.nil?
        puts '[TrimTool] STATE 1 click: ソリッドに当たりませんでした（スキップ）'
        return
      end

      if entity == @cutter
        puts '[TrimTool] STATE 1 click: カッター自身をクリック（スキップ）'
        return
      end

      unless manifold?(entity)
        puts "[TrimTool] STATE 1 click: 非マニフォールド → 操作不可 #{entity_label(entity)}"
        Sketchup.status_text = '警告：トリム対象がソリッドではありません。'
        return
      end

      unless bounding_boxes_intersect?(@cutter, entity)
        puts '[TrimTool] STATE 1 click: カッターと対象が交差していません（スキップ）'
        Sketchup.status_text = '警告：カッターと対象部材が交差していません。別の端部を選択してください。'
        return
      end

      puts "[TrimTool] STATE 1 click: トリム実行 target=#{entity_label(entity)}"
      execute_trim(entity, @cutter, click_pt, view)
    end

    # ----------------------------------------------------------------
    # ブーリアン演算の実行（ハーフスペースカッター法）
    #
    # 設計の核心:
    #   @cutter はカット平面特定のための参照専用。ブーリアン演算には渡さない。
    #   演算には一時生成した half_space_box を使い、subtract 後に両者は消える。
    #   → @cutter は絶対に保持される（連続トリムが可能）
    # ----------------------------------------------------------------
    def execute_trim(target, cutter, click_pt, view)
      model = Sketchup.active_model

      cut_info = find_cut_face(cutter, click_pt, cutter_transform: @cutter_global_transform)
      if cut_info.nil?
        puts '[TrimTool] execute_trim: カット平面が見つかりませんでした'
        UI.messagebox(
          "カット平面を検出できませんでした。\n" \
          "・カッター（境界ソリッド）とトリム対象が正しく交差しているか確認してください\n" \
          "・クリック位置を変えて再試行してください",
          MB_OK
        )
        return
      end
      puts "[TrimTool] execute_trim: カット平面検出 " \
           "center=#{cut_info[:center].to_s.gsub("\n", '')} " \
           "dot=#{cut_info[:dot].round(4)}"

      model.start_operation('Trim Solid', true)
      half_space = nil

      begin
        half_space = build_half_space_cutter(
          model,
          cut_info[:center],
          cut_info[:normal],
          target,
          click_pt
        )
        raise 'ハーフスペースカッターの生成に失敗しました' if half_space.nil?

        puts '[TrimTool] execute_trim: half_space.subtract(target) 実行中...'
        result     = half_space.subtract(target)
        half_space = nil

        raise 'ブーリアン演算が失敗しました（ソリッドが非マニフォールドの可能性があります）' if result.nil?

        cleanup_coplanar_edges(result)
        model.commit_operation
        puts "[TrimTool] execute_trim: 完了 result=#{entity_label(result)}"

        @hovered                 = nil
        @hovered_intersects      = false
        @preview_cut_info        = nil
        @hover_pt                = nil
        Sketchup.status_text = 'トリム完了。引き続き同じカッターで別の端部をトリムできます。ESC でカッター再選択。'

      rescue RuntimeError => e
        model.abort_operation
        half_space = nil
        puts "[TrimTool] execute_trim エラー: #{e.message}"
        UI.messagebox("トリム失敗：\n#{e.message}", MB_OK)
      end

      view.invalidate
    end

    # ----------------------------------------------------------------
    # カット平面プレビュー描画
    #
    # ターゲット BB をグレー細線で描画し、カット境界位置を
    # 半透明赤ポリゴン＋アウトラインで可視化する。
    # ----------------------------------------------------------------
    def draw_cut_plane_preview(view, entity, cut_info)
      return unless entity&.valid?

      draw_highlight(view, entity, COLOR_BB_PREVIEW, 1)

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

      view.drawing_color = COLOR_CUT_PLANE_FILL
      view.draw(GL_POLYGON, pts)

      view.line_width    = 2
      view.drawing_color = COLOR_CUT_PLANE_EDGE
      view.draw(GL_LINES, [pts[0], pts[1], pts[1], pts[2], pts[2], pts[3], pts[3], pts[0]])
    end

    def hovered_color
      return COLOR_NON_MANIFOLD unless @hovered && manifold?(@hovered)

      case @state
      when :cutter_selection
        COLOR_CUTTER_HOVER
      when :trim_target_selection
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
        '【トリム】1. カットの基準となる境界ソリッド（柱など）をクリックしてください'
      when :trim_target_selection
        '【トリム】2. 切り落として削除したいソリッドの端部をクリックしてください'
      else
        '処理中...'
      end
    end
  end
end

# frozen_string_literal: true

# sketchup_trim_plugin/main.rb
#
# メニュー登録と TrimTool クラス本体を記述する。
#
# ■ 状態遷移（ステートマシン）
#
#   STATE 0: :cutter_selection
#     ユーザーがカット境界となるソリッドをクリック → STATE 1 へ
#
#   STATE 1: :trim_target_selection
#     ユーザーが削除したい端部をクリック → ブーリアン演算 → STATE 1 に留まる
#     （同じカッターで連続トリム可能。ESC で STATE 0 へ戻る）
#
# ■ ハイライト色の意味
#   シアン  : カット境界ソリッド（STATE 0 ホバー / STATE 1 選択済み固定表示）
#   オレンジ: トリム可能なターゲット（交差あり）
#   紫      : 交差が検出できないターゲット（操作不可）
#   グレー  : 非マニフォールドのソリッド（操作不可）

module SketchupTrimPlugin
  # ----------------------------------------------------------------
  # メニュー登録（ファイル重複読み込み防止）
  # ----------------------------------------------------------------
  unless file_loaded?(__FILE__)
    plugins_menu = UI.menu('Plugins')
    submenu      = plugins_menu.add_submenu('Trim Solid Tool / トリムツール')

    submenu.add_item('トリムツールを起動') do
      Sketchup.active_model.select_tool(TrimTool.new)
    end

    file_loaded(__FILE__)
  end

  # ================================================================
  # TrimTool – 交差ソリッドのトリムツール
  # ================================================================
  class TrimTool
    # ---- ハイライト色定数 ----------------------------------------
    # STATE 0: ホバー中のカッター候補
    COLOR_CUTTER_HOVER    = Sketchup::Color.new(  0, 210, 255, 180)
    # STATE 1: 選択済みカッター（常時表示）
    COLOR_CUTTER_SELECTED = Sketchup::Color.new(  0, 210, 255, 230)
    # STATE 1: ホバー中の有効ターゲット（カッターと交差あり）
    COLOR_TARGET_VALID    = Sketchup::Color.new(255, 140,   0, 180)
    # STATE 1: ホバー中の無効ターゲット（カッターと交差なし）
    COLOR_TARGET_INVALID  = Sketchup::Color.new(160,   0, 200, 180)
    # 非マニフォールド（選択不可）
    COLOR_NON_MANIFOLD    = Sketchup::Color.new(140, 140, 140, 120)

    # BoundingBox の 12 辺を構成するコーナーインデックスペア
    # corners 配列は Geom::BoundingBox#corners の順序に準拠
    BB_EDGES = [
      [0, 1], [1, 3], [3, 2], [2, 0],  # 底面
      [4, 5], [5, 7], [7, 6], [6, 4],  # 上面
      [0, 4], [1, 5], [2, 6], [3, 7]   # 垂直辺
    ].freeze

    # ==============================================================
    # Sketchup::Tool コールバック
    # ==============================================================

    def activate
      puts '[TrimTool] activate: ツール起動'
      reset_state
      Sketchup.status_text = status_message
    end

    def deactivate(view)
      puts '[TrimTool] deactivate: ツール終了'
      view.invalidate
    end

    # ツールが前面に戻ったとき（ダイアログを閉じた後など）
    def resume(view)
      Sketchup.status_text = status_message
      view.invalidate
    end

    # ----------------------------------------------------------------
    # onMouseMove: ホバー対象を更新してハイライトを再描画
    # ----------------------------------------------------------------
    def onMouseMove(_flags, x, y, view)
      ph = view.pick_helper
      ph.do_pick(x, y)
      hovered = pick_solid(ph)

      case @state
      when :cutter_selection
        @hovered = hovered
        if @hovered
          puts "[TrimTool] STATE 0 hover: #{entity_label(@hovered)}"
        end

      when :trim_target_selection
        if hovered && hovered != @cutter
          @hovered            = hovered
          @hovered_intersects = bounding_boxes_intersect?(@cutter, @hovered)
          puts "[TrimTool] STATE 1 hover: #{entity_label(@hovered)} " \
               "intersects=#{@hovered_intersects}"
        else
          @hovered            = nil
          @hovered_intersects = false
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
      entity = pick_solid(ph)

      case @state
      when :cutter_selection
        on_cutter_click(entity, view)
      when :trim_target_selection
        on_trim_target_click(entity, view)
      end

      Sketchup.status_text = status_message
      view.invalidate
    end

    # ----------------------------------------------------------------
    # onKeyDown: ESC で前の状態に戻る
    # ----------------------------------------------------------------
    def onKeyDown(key, _repeat, _flags, view)
      return unless key == 27 # ESC

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
    # draw: バウンディングボックスのエッジでハイライト描画
    #       ※ draw コールバック内でのみ有効
    # ----------------------------------------------------------------
    def draw(view)
      draw_highlight(view, @cutter,  COLOR_CUTTER_SELECTED, 3) if @cutter
      draw_highlight(view, @hovered, hovered_color,          2) if @hovered
    end

    # ==============================================================
    # Private
    # ==============================================================
    private

    # ----------------------------------------------------------------
    # STATE 0 クリック処理: カッターを選択して STATE 1 へ遷移
    # ----------------------------------------------------------------
    def on_cutter_click(entity, _view)
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
      @cutter  = entity
      @hovered = nil
      @state   = :trim_target_selection
      puts '[TrimTool] → STATE 1 に遷移'
    end

    # ----------------------------------------------------------------
    # STATE 1 クリック処理: トリム対象を指定してブーリアン演算を実行
    # ----------------------------------------------------------------
    def on_trim_target_click(entity, view)
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
      execute_trim(entity, @cutter, view)
    end

    # ----------------------------------------------------------------
    # ブーリアン演算の実行
    #
    # Phase 1（現在）:
    #   target.trim(cutter) によるT字交差向けの直接トリム。
    #   trim は cutter を保持するため、同じカッターで連続トリムが可能。
    #
    # Phase 3（予定）:
    #   ハーフスペースカッター法に置き換え（貫通交差にも対応）。
    # ----------------------------------------------------------------
    def execute_trim(target, cutter, view)
      model = Sketchup.active_model
      model.start_operation('Trim Solid', true)

      begin
        puts '[TrimTool] execute_trim: target.trim(cutter) 実行中...'

        # NOTE: Group#trim は cutter を保持しつつ target をトリムした新グループを返す。
        #       戻り値が nil の場合は演算失敗（非マニフォールドなど）。
        result = target.trim(cutter)

        raise 'ブーリアン演算が失敗しました（ソリッドが非マニフォールドの可能性があります）' if result.nil?

        model.commit_operation
        puts "[TrimTool] execute_trim: 完了 result=#{entity_label(result)}"

        # 同じカッターで続けてトリムできるよう STATE 1 を維持（@cutter はそのまま）
        @hovered            = nil
        @hovered_intersects = false
        Sketchup.status_text = 'トリム完了。引き続き同じカッターで別の端部をトリムできます。ESC でカッター再選択。'
      rescue RuntimeError => e
        model.abort_operation
        puts "[TrimTool] execute_trim エラー: #{e.message}"
        UI.messagebox("トリム失敗：\n#{e.message}", MB_OK)
      end

      view.invalidate
    end

    # ----------------------------------------------------------------
    # PickHelper からソリッドエンティティ（Group/ComponentInstance）を取得
    #
    # best_picked が Face/Edge を返す場合（グループ編集モード中など）は
    # パスを辿って最も近い親グループを返す。
    # ----------------------------------------------------------------
    def pick_solid(ph)
      entity = ph.best_picked
      return nil unless entity

      # Group / ComponentInstance 以外（Face, Edge など）が返された場合はパスを辿る
      unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
        entity = find_enclosing_solid(ph)
      end

      return nil unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)

      entity
    end

    # ピックパスを逆順に辿り、最初に見つかった Group/ComponentInstance を返す
    def find_enclosing_solid(ph)
      0.upto(ph.count - 1) do |i|
        path = ph.path_at(i)
        next unless path

        solid = path.reverse_each.find do |e|
          e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
        end
        return solid if solid
      end
      nil
    end

    # ----------------------------------------------------------------
    # ソリッド（マニフォールド）判定
    # SketchUp 2014+（API 2.0+）は manifold?、旧バージョンは solid? を使用。
    # ----------------------------------------------------------------
    def manifold?(entity)
      entity.respond_to?(:manifold?) ? entity.manifold? : entity.solid?
    end

    # ----------------------------------------------------------------
    # BoundingBox による高速交差判定（AABB テスト）
    # ----------------------------------------------------------------
    def bounding_boxes_intersect?(a, b)
      return false unless a&.valid? && b&.valid?

      ba = a.bounds
      bb = b.bounds

      ba.min.x <= bb.max.x && ba.max.x >= bb.min.x &&
        ba.min.y <= bb.max.y && ba.max.y >= bb.min.y &&
        ba.min.z <= bb.max.z && ba.max.z >= bb.min.z
    end

    # ----------------------------------------------------------------
    # BoundingBox のエッジをワイヤーフレームで描画（draw 内専用）
    # ----------------------------------------------------------------
    def draw_highlight(view, entity, color, line_width)
      return unless entity&.valid?

      corners = entity.bounds.corners
      pts     = []
      BB_EDGES.each { |a_idx, b_idx| pts << corners[a_idx] << corners[b_idx] }

      view.line_width    = line_width
      view.drawing_color = color
      view.draw(GL_LINES, pts)
    end

    # ホバー中エンティティに適用するハイライト色を返す
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
      @state              = :cutter_selection
      @cutter             = nil
      @hovered            = nil
      @hovered_intersects = false
    end

    # ----------------------------------------------------------------
    # ステートに対応したステータスバーメッセージ
    # ----------------------------------------------------------------
    def status_message
      case @state
      when :cutter_selection
        '【カッター選択】カット境界となるソリッドをクリックしてください  |  ESC: ツール終了'
      when :trim_target_selection
        '【端部選択】削除する側の端部をクリックしてください  |  ESC: カッター再選択'
      else
        '処理中...'
      end
    end

    # デバッグ用エンティティ情報文字列
    def entity_label(entity)
      return 'nil' unless entity

      type     = entity.is_a?(Sketchup::Group) ? 'Group' : 'Component'
      is_solid = entity.valid? ? manifold?(entity).to_s : 'invalid'
      "#{type}(id=#{entity.object_id}, manifold=#{is_solid})"
    end
  end
end

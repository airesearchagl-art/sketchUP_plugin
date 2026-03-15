# frozen_string_literal: true

# su_smart_framing_tools/tools/align_tool.rb
#
# AlignTool – 基準面に対してターゲット部材の面をツラ揃えする（平行移動のみ）
#
# ■ 状態遷移（ステートマシン）
#   STATE 0: :reference_selection → 基準となる面（動かない側）を選択
#   STATE 1: :target_selection    → 揃えたい面（動かす側）を選択
#
# ■ アルゴリズム（execute_align）
#   1. 基準面をワールド座標に変換 → 平面方程式（法線 + 通過点）を算出
#   2. 移動面の中心点をワールド座標に変換
#   3. 移動面中心から基準平面への符号付き距離 d を算出
#      d = ref_normal · (target_center - ref_center)
#   4. 世界座標の移動ベクトル v_world = -d * ref_normal を計算
#   5. v_world を親エンティティのローカル座標に変換して平行移動を適用
#      target_entity.transform!(Geom::Transformation.translation(v_local))
#
# ■ フェイスピック
#   PickHelper のパスを走査し、Face + 最内 Group/ComponentInstance を抽出する
#   専用プライベートメソッド pick_face_with_transform を実装（GeometryHelper 非依存）
#
# ■ 幾何学処理は GeometryHelper に委譲（include SuSmartFramingTools::GeometryHelper）

module SuSmartFramingTools
  class AlignTool
    include GeometryHelper

    # ---- ハイライト色定数 ----------------------------------------
    COLOR_REF_HOVER       = Sketchup::Color.new(  0, 120, 255, 100)  # 青（STATE 0 ホバー）
    COLOR_REF_HOVER_EDGE  = Sketchup::Color.new(  0,  80, 220, 220)
    COLOR_REF_FIXED       = Sketchup::Color.new(  0, 120, 255, 140)  # 青（基準面 固定表示）
    COLOR_REF_FIXED_EDGE  = Sketchup::Color.new(  0,  60, 200, 230)
    COLOR_TGT_HOVER       = Sketchup::Color.new(  0, 200,  80, 100)  # 緑（STATE 1 ホバー）
    COLOR_TGT_HOVER_EDGE  = Sketchup::Color.new(  0, 160,  60, 220)

    # ==============================================================
    # Sketchup::Tool コールバック
    # ==============================================================

    def activate
      puts '[AlignTool] activate: ツール起動'
      reset_state
      Sketchup.status_text = status_message
    end

    def deactivate(view)
      puts '[AlignTool] deactivate: ツール終了'
      view.invalidate
    end

    def resume(view)
      Sketchup.status_text = status_message
      view.invalidate
    end

    # ----------------------------------------------------------------
    # onMouseMove: ホバー面を更新してプレビューを再描画
    # ----------------------------------------------------------------
    def onMouseMove(_flags, x, y, view)
      ph = view.pick_helper
      ph.do_pick(x, y)
      @hovered_face, @hovered_entity, @hovered_world_tf, @hovered_parent_tf =
        pick_face_with_transform(ph)
      view.invalidate
    end

    # ----------------------------------------------------------------
    # onLButtonDown: クリックによる状態遷移
    # ----------------------------------------------------------------
    def onLButtonDown(_flags, x, y, view)
      ph = view.pick_helper
      ph.do_pick(x, y)
      face, entity, world_tf, parent_tf = pick_face_with_transform(ph)

      case @state
      when :reference_selection
        on_reference_click(face, entity, world_tf, view)
      when :target_selection
        on_target_click(face, entity, world_tf, parent_tf, view)
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
      when :reference_selection
        puts '[AlignTool] ESC: ツール終了'
        Sketchup.active_model.select_tool(nil)
      when :target_selection
        puts '[AlignTool] ESC: STATE 0 に戻る（基準面選択解除）'
        reset_state
        Sketchup.status_text = status_message
        view.invalidate
      end
    end

    # ----------------------------------------------------------------
    # draw: フェイスポリゴンのハイライト描画
    #
    # STATE 0: ホバー面を青で表示
    # STATE 1: 基準面を青で常時表示 + ホバー面を緑で表示
    # ----------------------------------------------------------------
    def draw(view)
      # 基準面が選択済みなら常に青で描画
      if @ref_face&.valid?
        draw_face_polygon(view, @ref_face, @ref_world_tf,
                          COLOR_REF_FIXED, COLOR_REF_FIXED_EDGE, 2)
      end

      # ホバー面（基準面と同じ場合はスキップ）
      return unless @hovered_face&.valid? && @hovered_face != @ref_face

      case @state
      when :reference_selection
        draw_face_polygon(view, @hovered_face, @hovered_world_tf,
                          COLOR_REF_HOVER, COLOR_REF_HOVER_EDGE, 1)
      when :target_selection
        draw_face_polygon(view, @hovered_face, @hovered_world_tf,
                          COLOR_TGT_HOVER, COLOR_TGT_HOVER_EDGE, 1)
      end
    end

    # ==============================================================
    # Private
    # ==============================================================
    private

    # ----------------------------------------------------------------
    # STATE 0 クリック処理: 基準面を登録して STATE 1 へ遷移
    # ----------------------------------------------------------------
    def on_reference_click(face, entity, world_tf, _view)
      if face.nil? || entity.nil?
        puts '[AlignTool] STATE 0 click: 面が見つかりませんでした（スキップ）'
        return
      end

      puts "[AlignTool] STATE 0 click: 基準面を選択 → #{entity_label(entity)}"
      @ref_face     = face
      @ref_entity   = entity
      @ref_world_tf = world_tf
      @hovered_face = nil
      @state        = :target_selection
      puts '[AlignTool] → STATE 1 に遷移'
    end

    # ----------------------------------------------------------------
    # STATE 1 クリック処理: 移動面を確定してブーリアン（平行移動）を実行
    # ----------------------------------------------------------------
    def on_target_click(face, entity, world_tf, parent_tf, view)
      if face.nil? || entity.nil?
        puts '[AlignTool] STATE 1 click: 面が見つかりませんでした（スキップ）'
        return
      end

      if entity == @ref_entity
        puts '[AlignTool] STATE 1 click: 基準面と同一エンティティ（スキップ）'
        Sketchup.status_text = '警告：基準面と移動対象が同じ部材です。別の部材の面を選択してください。'
        return
      end

      puts "[AlignTool] STATE 1 click: 移動面を選択 → #{entity_label(entity)}"
      execute_align(@ref_face, @ref_world_tf,
                    face, entity, world_tf, parent_tf,
                    view)
    end

    # ----------------------------------------------------------------
    # 平行移動による面揃え（execute_align）
    #
    # ① ワールド座標で基準平面を定義（法線 + 通過点）
    # ② 移動面の中心点から基準平面への符号付き距離 d を算出
    # ③ ワールド移動ベクトル v_world = -d * ref_normal
    # ④ 親のワールド変換の逆行列を使いローカル座標に変換して transform! を適用
    #
    # ★ ローカル座標変換の必要性:
    #   entity.transform!(T) は「親エンティティのローカル座標空間での変換」を適用する。
    #   ルートレベルなら parent_tf = identity → v_local = v_world で問題なし。
    #   親グループ内に配置されている場合、parent_tf の逆行列で変換が必要。
    # ----------------------------------------------------------------
    def execute_align(ref_face, ref_world_tf,
                      target_face, target_entity, target_world_tf, target_parent_tf,
                      view)
      model = Sketchup.active_model

      # ---- ワールド座標での基準平面を算出 -------------------------
      ref_center = ref_face.bounds.center.transform(ref_world_tf)
      ref_normal = ref_face.normal.transform(ref_world_tf)
      ref_normal.normalize!

      # ---- ワールド座標での移動面中心を算出 -----------------------
      target_center = target_face.bounds.center.transform(target_world_tf)

      # ---- 基準平面への符号付き距離 d を算出 ----------------------
      # d > 0: target_center は基準平面の正法線側
      # d < 0: target_center は基準平面の負法線側
      # d ≈ 0: 既に揃っている
      d = ref_normal.dot(target_center - ref_center)

      puts "[AlignTool] execute_align: " \
           "ref_center=#{ref_center} ref_normal=#{ref_normal} " \
           "target_center=#{target_center} d=#{d.round(6)}"

      if d.abs < 1e-6
        puts '[AlignTool] execute_align: 既に位置合わせ済みです（d ≈ 0）'
        Sketchup.status_text = '情報：移動対象は既に基準面に揃っています。'
        return
      end

      # ---- 移動面と基準面の平行チェック（警告のみ・ブロックしない） ------
      target_normal_world = target_face.normal.transform(target_world_tf)
      target_normal_world.normalize!
      cross_len = ref_normal.cross(target_normal_world).length
      if cross_len > 1e-4
        puts "[AlignTool] execute_align: 警告 面が平行でありません (cross=#{cross_len.round(6)})"
        Sketchup.status_text = '警告：面が平行でないため、ツラ揃えにならない場合があります。'
      end

      # ---- ワールド空間の移動ベクトルを計算 ----------------------
      # v_world = -d * ref_normal
      v_world = Geom::Vector3d.new(
        ref_normal.x * (-d),
        ref_normal.y * (-d),
        ref_normal.z * (-d)
      )

      # ---- 親ローカル座標系に変換 --------------------------------
      # entity.transform!(T) は親ローカル座標系での変換を期待する。
      # target_parent_tf が identity（ルートレベル）の場合は変換不要。
      v_local = if target_parent_tf
                  v_world.transform(target_parent_tf.inverse)
                else
                  v_world
                end

      model.start_operation('Align Solid', true)
      begin
        target_entity.transform!(Geom::Transformation.translation(v_local))
        model.commit_operation

        puts "[AlignTool] execute_align: 完了 d=#{d.round(4)} inch " \
             "v_world=#{v_world.to_a.map { |n| n.round(3) }}"
        Sketchup.status_text = '位置合わせ完了。引き続き同じ基準面で別の部材を揃えられます。ESC で基準面再選択。'

        # STATE 1 を維持して連続操作を可能にする
        @hovered_face   = nil
        @hovered_entity = nil

      rescue StandardError => e
        model.abort_operation
        puts "[AlignTool] execute_align エラー: #{e.message}"
        UI.messagebox("位置合わせ失敗：\n#{e.message}", MB_OK)
      end

      view.invalidate
    end

    # ----------------------------------------------------------------
    # フェイスポリゴン描画（ワールド座標に変換済みの頂点で描画）
    #
    # GL_POLYGON: 半透明塗り
    # GL_LINES:   輪郭線（閉じたループ）
    # ----------------------------------------------------------------
    def draw_face_polygon(view, face, world_tf, fill_color, edge_color, line_width)
      return unless face&.valid?

      pts = face.outer_loop.vertices.map { |v| v.position.transform(world_tf) }
      return if pts.length < 3

      # 半透明塗り
      view.drawing_color = fill_color
      view.draw(GL_POLYGON, pts)

      # 輪郭線（閉じたループ）
      edge_pts = []
      pts.length.times do |i|
        edge_pts << pts[i]
        edge_pts << pts[(i + 1) % pts.length]
      end
      view.line_width    = line_width + 1
      view.drawing_color = edge_color
      view.draw(GL_LINES, edge_pts)
    end

    # ----------------------------------------------------------------
    # PickHelper からフェイスと親エンティティを取得（ネスト対応）
    #
    # ph.path_at(i) の例:
    #   ルートレベル Group:     [Group, Face]
    #   ネスト:                 [Group, ComponentInstance, Face]
    #
    # @return [Array(Face, entity, entity_world_tf, parent_world_tf)]
    #   Face:            クリックされた Sketchup::Face
    #   entity:          Face の直近の親 Group/ComponentInstance
    #   entity_world_tf: entity のワールド変換（ルートから entity まで累積）
    #   parent_world_tf: entity の「親」のワールド変換（entity 自身を除く累積）
    #                    ルートレベルなら Geom::Transformation.new（identity）
    # ----------------------------------------------------------------
    def pick_face_with_transform(ph)
      0.upto(ph.count - 1) do |i|
        path = ph.path_at(i)
        next unless path && !path.empty?

        face       = nil
        parent_idx = nil

        path.each_with_index do |e, j|
          if e.is_a?(Sketchup::Face)
            face = e
          elsif e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
            parent_idx = j
          end
        end

        next unless face && !parent_idx.nil?

        # entity_world_tf: ルートから parent_idx（含む）まで累積
        entity_world_tf = Geom::Transformation.new
        0.upto(parent_idx) do |j|
          e = path[j]
          entity_world_tf = entity_world_tf * e.transformation if e.respond_to?(:transformation)
        end

        # parent_world_tf: ルートから parent_idx（含まない）まで累積
        parent_world_tf = Geom::Transformation.new
        0.upto(parent_idx - 1) do |j|
          e = path[j]
          parent_world_tf = parent_world_tf * e.transformation if e.respond_to?(:transformation)
        end

        return [face, path[parent_idx], entity_world_tf, parent_world_tf]
      end

      [nil, nil, nil, nil]
    end

    # ----------------------------------------------------------------
    # 状態リセット（STATE 0 の初期状態に戻す）
    # ----------------------------------------------------------------
    def reset_state
      @state              = :reference_selection
      @ref_face           = nil
      @ref_entity         = nil
      @ref_world_tf       = nil
      @hovered_face       = nil
      @hovered_entity     = nil
      @hovered_world_tf   = nil
      @hovered_parent_tf  = nil
    end

    # ----------------------------------------------------------------
    # ステートに対応したステータスバーメッセージ
    # ----------------------------------------------------------------
    def status_message
      case @state
      when :reference_selection
        '【位置合わせ】1. 基準となる面（動かない側）をクリックしてください'
      when :target_selection
        '【位置合わせ】2. 揃えたい面（動かす側）をクリックしてください（ESC で基準面再選択）'
      else
        '処理中...'
      end
    end
  end
end

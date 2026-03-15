# frozen_string_literal: true

# su_smart_framing_tools/tools/extend_tool.rb
#
# ExtendTool – 境界面まで部材を延長し、はみ出し部をトリムするツール
#
# ■ 状態遷移（ステートマシン）
#   STATE 0: :boundary_selection → 境界となる基準面（ソリッドの面）を選択
#   STATE 1: :target_selection   → 延長したい部材の端面をクリック
#
# ■ execute_extend のコアアルゴリズム
#
#   交差済み・未到達どちらにも対応するため「オーバーシュート→トリム」方式を採用:
#
#   ① make_unique: ComponentInstance を固有化（他インスタンスへの影響を防止）
#   ② Face 再取得: make_unique 後に find_cut_face_object で Face 参照を再取得
#   ③ 到達距離計算:
#        denom = b_n · face_normal_world  （0 なら平行エラー）
#        t     = -b_n · (face_center - b_pt) / denom
#        overshoot_dist = |t| + 1000mm
#      t > 0: 境界まで面法線方向に t だけ進めば到達（未到達ケース）
#      t ≤ 0: 境界は逆方向にあるが、正方向に押し出して後でトリム（はみ出しケース）
#      いずれも正方向（face_normal 方向）に overshoot_dist だけ pushpull すれば
#      必ず境界を突き抜けた状態になる。
#   ④ PushPull: face.pushpull(+overshoot_dist)  ← 常に正値（face_normal 方向）
#   ⑤ waste_click_pt = face_center_world.offset(face_normal_world, overshoot_dist)
#      （PushPull 後の廃棄面中心 = 境界より先の点 → build_half_space_cutter の方向指定に使用）
#   ⑥ build_half_space_cutter(boundary_center, boundary_normal, waste_click_pt)
#      → cutter.subtract(target) で境界面より先を除去
#   ⑦ cleanup_coplanar_edges → commit_operation
#
# ■ 幾何学処理は GeometryHelper に委譲（include SuSmartFramingTools::GeometryHelper）

module SuSmartFramingTools
  class ExtendTool
    include GeometryHelper

    # ---- ハイライト色定数 ----------------------------------------
    COLOR_BOUNDARY_HOVER      = Sketchup::Color.new(  0, 120, 255, 100)  # 青（境界面 STATE 0 ホバー）
    COLOR_BOUNDARY_HOVER_EDGE = Sketchup::Color.new(  0,  80, 220, 230)
    COLOR_BOUNDARY_FIXED      = Sketchup::Color.new(  0, 120, 255, 140)  # 青（境界面 確定）
    COLOR_BOUNDARY_FIXED_EDGE = Sketchup::Color.new(  0,  60, 200, 240)
    COLOR_TARGET_HOVER        = Sketchup::Color.new(  0, 200,  80, 100)  # 緑（延長対象面 ホバー）
    COLOR_TARGET_HOVER_EDGE   = Sketchup::Color.new(  0, 160,  60, 230)
    COLOR_NON_MANIFOLD        = Sketchup::Color.new(140, 140, 140, 120)  # グレー（非マニフォールド）
    COLOR_BB_WIRE             = Sketchup::Color.new( 80,  80,  80, 160)  # グレー細線

    # ==============================================================
    # Sketchup::Tool コールバック
    # ==============================================================

    def activate
      puts '[ExtendTool] activate: ツール起動'
      reset_state
      Sketchup.status_text = status_message
    end

    def deactivate(view)
      puts '[ExtendTool] deactivate: ツール終了'
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
      hovered, hovered_tf = pick_solid_with_transform(ph)

      ip = Sketchup::InputPoint.new
      ip.pick(view, x, y)
      @hover_pt = ip.position

      case @state
      when :boundary_selection
        @hovered    = hovered
        @hovered_tf = hovered_tf
        @preview_cut_info = if @hovered && manifold?(@hovered)
                              find_cut_face(@hovered, @hover_pt,
                                            cutter_transform: @hovered_tf,
                                            quiet: true)
                            end

      when :target_selection
        if hovered && hovered != @boundary_entity
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
      when :boundary_selection
        on_boundary_click(entity, entity_tf, click_pt, view)
      when :target_selection
        on_target_click(entity, entity_tf, click_pt, view)
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
      when :boundary_selection
        puts '[ExtendTool] ESC: ツール終了'
        Sketchup.active_model.select_tool(nil)
      when :target_selection
        puts '[ExtendTool] ESC: STATE 0 に戻る（境界再選択）'
        reset_state
        Sketchup.status_text = status_message
        view.invalidate
      end
    end

    # ----------------------------------------------------------------
    # draw: 面ハイライト＆カット平面プレビューの描画
    #
    # STATE 0: ホバー面を青で表示
    # STATE 1: 確定済み境界面を青で常時表示 + ホバー延長面を緑で表示
    # ----------------------------------------------------------------
    def draw(view)
      # 確定済み境界のカット面を常に青で描画（STATE 1 のみ）
      if @state == :target_selection && @boundary_cut_info
        draw_cut_plane(view, @boundary_cut_info, COLOR_BOUNDARY_FIXED, COLOR_BOUNDARY_FIXED_EDGE)
      end

      # ホバー中エンティティのカット面（または BB フォールバック）
      if @hovered&.valid?
        if @preview_cut_info
          fill  = @state == :boundary_selection ? COLOR_BOUNDARY_HOVER      : COLOR_TARGET_HOVER
          edge  = @state == :boundary_selection ? COLOR_BOUNDARY_HOVER_EDGE : COLOR_TARGET_HOVER_EDGE
          draw_highlight(view, @hovered, COLOR_BB_WIRE, 1)
          draw_cut_plane_polygon(view, @hovered, @preview_cut_info, fill, edge)
        else
          color = manifold?(@hovered) ? COLOR_BOUNDARY_HOVER : COLOR_NON_MANIFOLD
          draw_highlight(view, @hovered, color, 2)
        end
      end
    end

    # ==============================================================
    # Private
    # ==============================================================
    private

    # ----------------------------------------------------------------
    # STATE 0 クリック処理: 境界面をキャッシュして STATE 1 へ遷移
    # ----------------------------------------------------------------
    def on_boundary_click(entity, entity_tf, click_pt, _view)
      if entity.nil?
        puts '[ExtendTool] STATE 0 click: ソリッドが見つかりませんでした（スキップ）'
        return
      end
      unless manifold?(entity)
        Sketchup.status_text = '警告：選択した部材はソリッドではありません。'
        return
      end

      cut_info = find_cut_face(entity, click_pt, cutter_transform: entity_tf)
      if cut_info.nil?
        Sketchup.status_text = '警告：境界面を検出できませんでした。面の付近をクリックしてください。'
        return
      end

      puts "[ExtendTool] STATE 0 click: 境界を登録 → #{entity_label(entity)}"
      @boundary_entity   = entity
      @boundary_cut_info = cut_info   # ワールド座標でキャッシュ（以降変更しない）
      @hovered           = nil
      @hovered_tf        = nil
      @preview_cut_info  = nil
      @state             = :target_selection
      puts '[ExtendTool] → STATE 1 に遷移'
    end

    # ----------------------------------------------------------------
    # STATE 1 クリック処理: 延長対象面を確定して execute_extend を起動
    # ----------------------------------------------------------------
    def on_target_click(entity, entity_tf, click_pt, view)
      if entity.nil?
        puts '[ExtendTool] STATE 1 click: ソリッドが見つかりませんでした（スキップ）'
        return
      end
      if entity == @boundary_entity
        Sketchup.status_text = '警告：境界と同じ部材です。別の部材を選択してください。'
        return
      end
      unless manifold?(entity)
        Sketchup.status_text = '警告：選択した部材はソリッドではありません。'
        return
      end

      puts "[ExtendTool] STATE 1 click: 延長対象を確定 → #{entity_label(entity)}"
      execute_extend(entity, entity_tf, click_pt, view)
    end

    # ----------------------------------------------------------------
    # オーバーシュート→トリム方式による延長（execute_extend）
    #
    # ─────────────────────────────────────────────────────
    # 距離計算の原理（t の算出）:
    #
    #   face_normal_world 方向にパラメータ t だけ進んだ点が境界平面上に乗る条件:
    #     b_n · (face_center + t * face_normal - b_pt) = 0
    #     t = -b_n · (face_center - b_pt) / (b_n · face_normal)
    #
    #   t > 0 … 境界は face_normal 方向にある（未到達 → 延長）
    #   t ≤ 0 … 境界は逆方向にある（はみ出し → 正方向に押し出してから切断）
    #
    # 常に正方向（+face_normal）に overshoot_dist だけ pushpull することで
    # 両ケースともに「境界を確実に突き抜けた状態」を作り出せる。
    # ─────────────────────────────────────────────────────
    def execute_extend(target_entity, target_entity_tf, target_click_pt, view)
      model = Sketchup.active_model
      model.start_operation('Extend Solid', true)
      cutter = nil

      begin
        # ---- ① ComponentInstance を固有化 ---------------------------
        target_entity.make_unique if target_entity.is_a?(Sketchup::ComponentInstance)

        # ---- ② make_unique 後に Face オブジェクトを再取得 -----------
        # make_unique で定義が差し替わるため、click_pt を使って再探索する
        face = find_cut_face_object(target_entity, target_click_pt,
                                    entity_transform: target_entity_tf)
        raise '延長対象の面を取得できませんでした（make_unique 後）' if face.nil?

        # ---- ③ face のワールド座標を取得 ----------------------------
        face_center_world = face.bounds.center.transform(target_entity_tf)
        face_normal_world = face.normal.transform(target_entity_tf)
        face_normal_world.normalize!

        b_n  = @boundary_cut_info[:normal]   # ワールド境界法線
        b_pt = @boundary_cut_info[:center]   # ワールド境界中心点

        # ---- ④ 到達距離 t を算出（平行チェック付き）----------------
        denom = b_n.dot(face_normal_world)
        if denom.abs < 1e-6
          raise '延長対象の面と境界面が平行のため延長できません。' \
                '別の面または別の境界を選択してください。'
        end

        t             = -b_n.dot(face_center_world - b_pt) / denom
        overshoot_dist = t.abs + 1000.mm  # 境界を確実に突き抜ける距離

        puts "[ExtendTool] execute_extend: " \
             "t=#{t.round(3)}in  overshoot=#{overshoot_dist.round(1)}in  " \
             "denom=#{denom.round(4)}"

        # ---- ⑤ PushPull（常に face_normal 正方向）------------------
        # face.pushpull は face のローカル法線方向に dist だけ押し出す。
        # 正値 = face_normal 方向へ押し出し（外向き延伸）。
        # t > 0 でも t ≤ 0 でも overshoot_dist > 0 を使えば
        # 境界を突き抜けた状態が保証される。
        face.pushpull(overshoot_dist)
        puts '[ExtendTool] execute_extend: PushPull 完了'

        # ---- ⑥ waste_click_pt を算出（境界より先の廃棄領域に置く）--
        # build_half_space_cutter がカッターを「waste 側」に生成するための
        # 方向指定点。face_normal 方向に overshoot 分だけ進んだ点を使う。
        waste_click_pt = face_center_world.offset(face_normal_world, overshoot_dist)

        # ---- ⑦ ハーフスペースカッターを生成してトリム ---------------
        n_b    = b_n.clone
        cutter = build_half_space_cutter(model, b_pt, n_b,
                                         target_entity, waste_click_pt)
        raise '境界カッターの生成に失敗しました' if cutter.nil?

        puts '[ExtendTool] execute_extend: cutter.subtract(target) 実行中...'
        result = cutter.subtract(target_entity)
        cutter = nil   # subtract 成功時は API が cutter を自動削除済み
        raise 'ブーリアン演算（境界でのトリム）が失敗しました' if result.nil?

        # ---- ⑧ 共面エッジのクリーンアップ & コミット ---------------
        cleanup_coplanar_edges(result)
        model.commit_operation

        puts "[ExtendTool] execute_extend: 完了 result=#{entity_label(result)}"
        Sketchup.status_text = '延長完了。引き続き同じ境界に別の部材を延長できます。ESC で境界再選択。'

        # STATE 1 を維持して連続延長を可能にする
        @hovered          = nil
        @hovered_tf       = nil
        @preview_cut_info = nil

      rescue RuntimeError => e
        model.abort_operation
        cutter = nil
        puts "[ExtendTool] execute_extend エラー: #{e.message}"
        UI.messagebox("延長失敗：\n#{e.message}", MB_OK)
      end

      view.invalidate
    end

    # ----------------------------------------------------------------
    # カット面 Face オブジェクトを返す（GeometryHelper#find_cut_face の Face 返し版）
    #
    # make_unique 後に有効な Face 参照を取得するために使用する。
    # 「click_pt 方向を向く最近接面」を探して Sketchup::Face を返す。
    #
    # @return [Sketchup::Face, nil]
    # ----------------------------------------------------------------
    def find_cut_face_object(entity, click_pt, entity_transform: nil)
      ents      = entity.is_a?(Sketchup::Group) ? entity.entities : entity.definition.entities
      transform = entity_transform || entity.transformation

      best_face = nil
      best_dist = Float::INFINITY

      ents.grep(Sketchup::Face).each do |face|
        center_world = face.bounds.center.transform(transform)
        normal_world = face.normal.transform(transform)
        normal_world.normalize!

        dot = normal_world.dot(click_pt - center_world)
        next if dot <= 0.0

        dist = center_world.distance(click_pt)
        if dist < best_dist
          best_dist = dist
          best_face = face
        end
      end

      best_face
    end

    # ----------------------------------------------------------------
    # 確定済み境界のカット面ポリゴンを描画（基準点 + 法線から頂点を生成）
    # ----------------------------------------------------------------
    def draw_cut_plane(view, cut_info, fill_color, edge_color)
      center    = cut_info[:center]
      normal    = cut_info[:normal]
      half_size = 36.0.inch  # 固定サイズ（境界エンティティなしでも描画可能）

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
    # ホバー時のカット面ポリゴン描画（エンティティ BB サイズに合わせる）
    # ----------------------------------------------------------------
    def draw_cut_plane_polygon(view, entity, cut_info, fill_color, edge_color)
      return unless entity&.valid?

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
      @state             = :boundary_selection
      @boundary_entity   = nil
      @boundary_cut_info = nil
      @hovered           = nil
      @hovered_tf        = nil
      @hover_pt          = nil
      @preview_cut_info  = nil
    end

    # ----------------------------------------------------------------
    # ステートに対応したステータスバーメッセージ
    # ----------------------------------------------------------------
    def status_message
      case @state
      when :boundary_selection
        '【延長】1. 境界となる面をクリックしてください'
      when :target_selection
        '【延長】2. 延長したい部材の端面をクリックしてください（ESC で境界再選択）'
      else
        '処理中...'
      end
    end
  end
end

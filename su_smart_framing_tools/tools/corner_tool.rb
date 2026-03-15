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
        Sketchup.status_text = '警告：カット面を検出できませんでした。削除したい側をクリックしてください。'
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
        Sketchup.status_text = '警告：カット面を検出できませんでした。削除したい側をクリックしてください。'
        return
      end

      puts "[CornerTool] STATE 1 click: 部材B を確定 → #{entity_label(entity)}"
      execute_corner(@member_a, @member_a_tf, @click_pt_a, @cut_info_a,
                     entity, entity_tf, click_pt, cut_info_b,
                     view)
    end

    # ----------------------------------------------------------------
    # t値ベースの強制延伸＆相互トリムによるコーナー処理（execute_corner）
    #
    # ① make_unique（ComponentInstance を固有化）
    # ② カット面オブジェクトを再取得（make_unique 後に定義が変わるため）
    # ③ PushPull: t値で「相手境界面まで到達する距離 + 余裕」を算出して延伸
    #    - denom = b_n.dot(a_n) が 0 に近い（面が平行/垂直）場合は対角線ベースのフォールバック
    # ④ build_half_space_cutter で相手境界面からカッターを生成
    # ⑤ subtract × 2 → cleanup × 2 → commit
    # ----------------------------------------------------------------
    def execute_corner(member_a, member_a_tf, click_pt_a, cut_info_a,
                       member_b, member_b_tf, click_pt_b, cut_info_b,
                       view)
      model = Sketchup.active_model

      a_pt = cut_info_a[:center]
      a_n  = cut_info_a[:normal].clone
      b_pt = cut_info_b[:center]
      b_n  = cut_info_b[:normal].clone

      diag_a        = member_a.bounds.min.distance(member_a.bounds.max)
      diag_b        = member_b.bounds.min.distance(member_b.bounds.max)
      fallback_dist = [diag_a, diag_b].max * 2 + 1000.mm

      denom = b_n.dot(a_n)
      if denom.abs >= 1e-6
        t_a = -b_n.dot(a_pt - b_pt) / denom
        t_b = -a_n.dot(b_pt - a_pt) / denom
        overshoot_a = t_a.abs + 1000.mm
        overshoot_b = t_b.abs + 1000.mm
      else
        overshoot_a = fallback_dist
        overshoot_b = fallback_dist
      end

      model.start_operation('Corner Solid', true)
      cutter_a = nil
      cutter_b = nil

      begin
        # ---- ① ComponentInstance を固有化 --------------------------------
        member_a.make_unique if member_a.is_a?(Sketchup::ComponentInstance)
        member_b.make_unique if member_b.is_a?(Sketchup::ComponentInstance)

        # ---- ② make_unique 後にカット面オブジェクトを再取得 ----------------
        face_a = find_cut_face_object(member_a, click_pt_a, entity_transform: member_a_tf)
        raise '部材Aのカット面オブジェクトを取得できませんでした（make_unique 後）' if face_a.nil?

        face_b = find_cut_face_object(member_b, click_pt_b, entity_transform: member_b_tf)
        raise '部材Bのカット面オブジェクトを取得できませんでした（make_unique 後）' if face_b.nil?

        # ---- ③ PushPull: t値ベースの距離で強制延伸 -----------------------
        puts "[CornerTool] execute_corner: PushPull " \
             "A=#{overshoot_a.to_f.round(1)}in B=#{overshoot_b.to_f.round(1)}in"
        face_a.pushpull(overshoot_a)
        face_b.pushpull(overshoot_b)

        # ---- ④ ハーフスペースカッターを生成 --------------------------------
        # waste_pt: 延伸した余分な側にある点（build_half_space_cutter の方向決定用）
        waste_pt_a = a_pt.offset(a_n, overshoot_a)
        waste_pt_b = b_pt.offset(b_n, overshoot_b)

        cutter_a = build_half_space_cutter(model, b_pt, b_n, member_a, waste_pt_a)
        raise 'カッターA（部材A 用）の生成に失敗しました' if cutter_a.nil?

        cutter_b = build_half_space_cutter(model, a_pt, a_n, member_b, waste_pt_b)
        raise 'カッターB（部材B 用）の生成に失敗しました' if cutter_b.nil?

        # ---- ⑤ 相互 subtract -------------------------------------------
        puts '[CornerTool] execute_corner: cutter_a.subtract(member_a) 実行中...'
        res_a    = cutter_a.subtract(member_a)
        cutter_a = nil
        raise 'ブーリアン演算（部材A のトリム）が失敗しました' if res_a.nil?

        puts '[CornerTool] execute_corner: cutter_b.subtract(member_b) 実行中...'
        res_b    = cutter_b.subtract(member_b)
        cutter_b = nil
        raise 'ブーリアン演算（部材B のトリム）が失敗しました' if res_b.nil?

        # ---- ⑥ 共面エッジのクリーンアップ ---------------------------------
        cleanup_coplanar_edges(res_a)
        cleanup_coplanar_edges(res_b)

        model.commit_operation
        puts "[CornerTool] execute_corner: 完了 " \
             "res_a=#{entity_label(res_a)} res_b=#{entity_label(res_b)}"
        Sketchup.status_text = 'コーナー処理完了。ESC で次の部材Aを選択できます。'
        reset_state

      rescue RuntimeError => e
        model.abort_operation
        cutter_a&.erase! if cutter_a&.valid?
        cutter_b&.erase! if cutter_b&.valid?
        puts "[CornerTool] execute_corner エラー: #{e.message}"
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
        '【包絡】1. 1つ目の部材の「削除したい側」をクリックしてください'
      when :select_member_b
        '【包絡】2. 2つ目の部材の「削除したい側」をクリックしてください（ESC で部材A 再選択）'
      else
        '処理中...'
      end
    end
  end
end

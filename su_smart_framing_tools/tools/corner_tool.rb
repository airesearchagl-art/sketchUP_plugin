# frozen_string_literal: true

# su_smart_framing_tools/tools/corner_tool.rb
#
# CornerTool – 交差する2部材を相互トリムしてL字コーナーを生成するツール
#
# ■ 状態遷移（ステートマシン）
#   STATE 0: :select_member_a → 1つ目の部材（削られる境界面をクリック）
#   STATE 1: :select_member_b → 2つ目の部材（削られる境界面をクリック）
#
# ■ 相互トリムアルゴリズム（execute_corner）
#   ① 部材Aのクリック位置から find_cut_face でカット平面 cut_info_a を取得
#   ② 部材Bのクリック位置から find_cut_face でカット平面 cut_info_b を取得
#   ③ build_half_space_cutter(cut_info_a) → cutter_a（部材Bを削るカッター）
#   ④ build_half_space_cutter(cut_info_b) → cutter_b（部材Aを削るカッター）
#   ⑤ res_b = cutter_a.subtract(member_b)   ← AのカッターでBを削る
#   ⑥ res_a = cutter_b.subtract(member_a)   ← BのカッターでAを削る
#   ⑦ cleanup_coplanar_edges(res_a), cleanup_coplanar_edges(res_b)
#   ⑧ commit_operation（失敗時は abort_operation で全ロールバック）
#
# ■ ユーザー操作イメージ
#   クリック位置は「削除したい側」（はみ出し部分の内側）を示す。
#   find_cut_face がクリック点に向いている面（境界面）を自動検出し、
#   その面を起点にハーフスペースカッターを生成する。
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
      ph.do_pick(x, y)
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
    # STATE 0 クリック処理: 部材Aとカット平面を登録して STATE 1 へ遷移
    # ----------------------------------------------------------------
    def on_member_a_click(entity, entity_tf, click_pt, _view)
      if entity.nil?
        puts '[CornerTool] STATE 0 click: ソリッドが見つかりませんでした（スキップ）'
        return
      end

      unless manifold?(entity)
        puts "[CornerTool] STATE 0 click: 非マニフォールド → 選択不可 #{entity_label(entity)}"
        Sketchup.status_text = '警告：選択した部材はソリッドではありません。別の部材を選択してください。'
        return
      end

      cut_info = find_cut_face(entity, click_pt, cutter_transform: entity_tf)
      if cut_info.nil?
        puts '[CornerTool] STATE 0 click: カット平面を検出できませんでした'
        Sketchup.status_text = '警告：カット面を検出できませんでした。削除したい側の面付近をクリックしてください。'
        return
      end

      puts "[CornerTool] STATE 0 click: 部材A を登録 → #{entity_label(entity)}"
      @member_a    = entity
      @member_a_tf = entity_tf
      @click_pt_a  = click_pt
      @cut_info_a  = cut_info
      @hovered     = nil
      @hovered_tf  = nil
      @preview_cut_info = nil
      @state       = :select_member_b
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
        puts '[CornerTool] STATE 1 click: 部材Aと同一エンティティ（スキップ）'
        Sketchup.status_text = '警告：部材Aと同じ部材です。別の部材を選択してください。'
        return
      end

      unless manifold?(entity)
        puts "[CornerTool] STATE 1 click: 非マニフォールド → 選択不可 #{entity_label(entity)}"
        Sketchup.status_text = '警告：選択した部材はソリッドではありません。別の部材を選択してください。'
        return
      end

      cut_info_b = find_cut_face(entity, click_pt, cutter_transform: entity_tf)
      if cut_info_b.nil?
        puts '[CornerTool] STATE 1 click: カット平面を検出できませんでした'
        Sketchup.status_text = '警告：カット面を検出できませんでした。削除したい側の面付近をクリックしてください。'
        return
      end

      puts "[CornerTool] STATE 1 click: 部材B を確定 → #{entity_label(entity)} → コーナー処理開始"
      execute_corner(@member_a, @cut_info_a, @click_pt_a,
                     entity, cut_info_b, click_pt,
                     view)
    end

    # ----------------------------------------------------------------
    # 相互トリムによるコーナー処理（execute_corner）
    #
    # ★ カッター生成の方向性:
    #   - cutter_a は cut_info_a（部材Aの境界面）から click_pt_a 方向へ延伸
    #     → 部材Bの「click_pt_a 側」をカットする
    #   - cutter_b は cut_info_b（部材Bの境界面）から click_pt_b 方向へ延伸
    #     → 部材Aの「click_pt_b 側」をカットする
    #
    # ★ 法線ベクトルは clone して渡す:
    #   build_half_space_cutter が plane_n.reverse! で in-place 変更する可能性があるため。
    #
    # ★ Undo 設計:
    #   abort_operation により cutter_a/cutter_b の生成・subtract 結果をすべてロールバック。
    # ----------------------------------------------------------------
    def execute_corner(member_a, cut_info_a, click_pt_a,
                       member_b, cut_info_b, click_pt_b,
                       view)
      model = Sketchup.active_model
      model.start_operation('Corner Solid', true)
      cutter_a = nil
      cutter_b = nil

      begin
        # ---- cutter_a: cut_info_a の面から click_pt_a 方向へ → member_b を削る ----
        n_a      = cut_info_a[:normal].clone
        cutter_a = build_half_space_cutter(model, cut_info_a[:center], n_a,
                                           member_b, click_pt_a)
        raise 'カッターA（部材B 用）の生成に失敗しました' if cutter_a.nil?

        # ---- cutter_b: cut_info_b の面から click_pt_b 方向へ → member_a を削る ----
        n_b      = cut_info_b[:normal].clone
        cutter_b = build_half_space_cutter(model, cut_info_b[:center], n_b,
                                           member_a, click_pt_b)
        raise 'カッターB（部材A 用）の生成に失敗しました' if cutter_b.nil?

        # ---- AのカッターでBを削る ----------------------------------------
        puts '[CornerTool] execute_corner: cutter_a.subtract(member_b) 実行中...'
        res_b    = cutter_a.subtract(member_b)
        cutter_a = nil  # subtract 成功時は API が cutter を自動削除済み
        raise 'ブーリアン演算（部材B のトリム）が失敗しました' if res_b.nil?

        # ---- BのカッターでAを削る ----------------------------------------
        puts '[CornerTool] execute_corner: cutter_b.subtract(member_a) 実行中...'
        res_a    = cutter_b.subtract(member_a)
        cutter_b = nil  # subtract 成功時は API が cutter を自動削除済み
        raise 'ブーリアン演算（部材A のトリム）が失敗しました' if res_a.nil?

        # ---- 断面の共面エッジをクリーンアップ ------------------------------
        cleanup_coplanar_edges(res_a)
        cleanup_coplanar_edges(res_b)

        model.commit_operation
        puts "[CornerTool] execute_corner: 完了 " \
             "res_a=#{entity_label(res_a)} res_b=#{entity_label(res_b)}"
        Sketchup.status_text = 'コーナー処理完了。ESC で次の部材Aを選択できます。'

        # 処理完了後は STATE 0 にリセット（次のコーナー操作に備える）
        reset_state

      rescue RuntimeError => e
        model.abort_operation
        cutter_a = nil
        cutter_b = nil
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

      # ターゲット BB をグレー細線で描画（形状把握）
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

      # 半透明ポリゴン
      view.drawing_color = fill_color
      view.draw(GL_POLYGON, pts)

      # 輪郭線
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

# frozen_string_literal: true

# sketchup_trim_plugin/main.rb
#
# メニュー登録と TrimTool クラス本体。
#
# ■ 状態遷移（ステートマシン）
#
#   STATE 0: :cutter_selection
#     1. ユーザーがカット境界となるソリッド（柱など）をクリック → STATE 1 へ
#
#   STATE 1: :trim_target_selection
#     2. ユーザーが切り落とす側の端部をクリック → ハーフスペースカッター法で演算 → STATE 1 維持
#        （同じカッターで連続トリム可能。ESC で STATE 0 へ戻る）
#
# ■ アーキテクチャの要点（Phase 3）
#   @cutter は「カット平面特定のための参照専用」。ブーリアン演算には渡さない。
#   演算には一時生成した half_space_box を使い、subtract 後に両者（target + box）は消える。
#   → @cutter（柱など境界ソリッド）は絶対に保持される。
#
# ■ ハーフスペースカッター法のコアロジック
#
#   find_cut_face:
#     カッターの各フェイスの法線ベクトル plane_n と
#     クリック点への方向ベクトル (click_pt - plane_pt) の内積を計算。
#     内積 > 0 ならそのフェイスが「削除側を向いている」ことを示す。
#
#   build_half_space_cutter:
#     dot = plane_n.dot(click_pt - plane_pt) の値で延伸距離を動的に決定。
#     内積の絶対値 = カット平面からクリック点までの射影距離。
#     この距離の2倍 + 余裕 を延伸長とすることで T字・貫通どちらにも対応。
#
# ■ ハイライト色（Phase 5 追加）
#   シアン       : カット境界ソリッド（STATE 0 ホバー / STATE 1 固定表示）
#   オレンジ     : トリム可能なターゲット（通常ホバー / カッターと交差あり）
#   グレー細線   : カット平面プレビュー時のターゲット BB（形状把握用）
#   半透明赤面   : カット境界を示す平面ポリゴン（どこで切れるかを可視化）
#   赤アウトライン: カット平面の縁取り線
#   紫           : 交差が検出できないターゲット（操作不可）
#   グレー       : 非マニフォールドのソリッド（操作不可）

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

    # 右クリックコンテキストメニューにも追加
    UI.add_context_menu_handler do |menu|
      menu.add_item('トリムツールを起動') do
        Sketchup.active_model.select_tool(TrimTool.new)
      end
    end

    file_loaded(__FILE__)
  end

  # ================================================================
  # TrimTool – 交差ソリッドのトリムツール（ハーフスペースカッター法）
  # ================================================================
  class TrimTool
    # ---- ハイライト色定数 ----------------------------------------
    COLOR_CUTTER_HOVER    = Sketchup::Color.new(  0, 210, 255, 180)  # シアン（STATE 0 ホバー）
    COLOR_CUTTER_SELECTED = Sketchup::Color.new(  0, 210, 255, 230)  # シアン（STATE 1 固定）
    COLOR_TARGET_VALID    = Sketchup::Color.new(255, 140,   0, 180)  # オレンジ（保持側 / 交差あり）
    COLOR_TARGET_INVALID  = Sketchup::Color.new(160,   0, 200, 180)  # 紫（交差なし）
    COLOR_NON_MANIFOLD    = Sketchup::Color.new(140, 140, 140, 120)  # グレー（非マニフォールド）
    COLOR_BB_PREVIEW      = Sketchup::Color.new( 80,  80,  80, 160)  # グレー細線（カット面プレビュー時の BB）
    COLOR_CUT_PLANE_FILL  = Sketchup::Color.new(255,   0,   0, 100)  # 半透明赤（カット境界面ポリゴン）
    COLOR_CUT_PLANE_EDGE  = Sketchup::Color.new(220,  30,  30, 220)  # 赤（カット境界面アウトライン）

    # BoundingBox の 12 辺（corners インデックスペア）
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
      # グローバル変換付きでソリッドを取得（ネストされたコンポーネント対応）
      hovered, = pick_solid_with_transform(ph)

      case @state
      when :cutter_selection
        @hovered = hovered
        puts "[TrimTool] STATE 0 hover: #{entity_label(@hovered)}" if @hovered

      when :trim_target_selection
        # ホバー座標をワールド座標で取得（削除プレビューに使用）
        ip = Sketchup::InputPoint.new
        ip.pick(view, x, y)
        @hover_pt = ip.position

        if hovered && hovered != @cutter
          @hovered            = hovered
          @hovered_intersects = bounding_boxes_intersect?(@cutter, @hovered)
          # カット平面を事前計算（puts を抑制した quiet モードで呼び出し）
          # @cutter_global_transform を使用してネストされたカッターも正確に変換
          @preview_cut_info = if @hovered_intersects && manifold?(@hovered)
                                find_cut_face(@cutter, @hover_pt,
                                              cutter_transform: @cutter_global_transform,
                                              quiet: true)
                              end
          puts "[TrimTool] STATE 1 hover: #{entity_label(@hovered)} " \
               "intersects=#{@hovered_intersects} preview=#{!@preview_cut_info.nil?}"
        else
          @hovered          = nil
          @hovered_intersects = false
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
      # グローバル変換付きでソリッドを取得（ネストされたコンポーネント対応）
      entity, entity_transform = pick_solid_with_transform(ph)

      case @state
      when :cutter_selection
        on_cutter_click(entity, entity_transform, view)

      when :trim_target_selection
        # STATE 1: クリック点をワールド座標で取得（ハーフスペースカッター法に使用）
        ip = Sketchup::InputPoint.new
        ip.pick(view, x, y)
        click_pt = ip.position  # Geom::Point3d（ワールド座標）
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
    # draw: バウンディングボックスのエッジでハイライト描画
    #
    # STATE 1 でターゲット候補にホバー中かつ preview_cut_info がある場合は、
    # draw_cut_plane_preview により「どこで切れるか」を半透明赤ポリゴンで可視化する。
    # ターゲット BB はグレー細線のみとし、カット面（刃）で削除位置を表現。
    # ※ draw コールバック内でのみ有効
    # ----------------------------------------------------------------
    def draw(view)
      draw_highlight(view, @cutter, COLOR_CUTTER_SELECTED, 3) if @cutter

      if @hovered
        if @state == :trim_target_selection && @hovered_intersects && @preview_cut_info
          # カット平面プレビューモード: BB はグレー細線 + カット境界を赤ポリゴンで表示
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
      # ネスト対応: ピック時の累積変換をグローバル変換として保持
      # nil の場合は entity.transformation にフォールバック（単体エンティティや API 非対応時）
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
    # ブーリアン演算の実行（Phase 3: ハーフスペースカッター法）
    #
    # 設計の核心:
    #   @cutter（柱など境界ソリッド）は find_cut_face のカット平面特定にのみ使用。
    #   実際のブーリアン演算では一時生成した half_space_box で subtract を行う。
    #   → @cutter は演算に関与しないため絶対に保持される（連続トリムが可能）
    #   → half_space.subtract(target) の戻り値はトリム済みの target（完成品）
    # ----------------------------------------------------------------
    def execute_trim(target, cutter, click_pt, view)
      model = Sketchup.active_model

      # ---- Step 1: カット平面の特定（内積による方向判定） -----
      # @cutter_global_transform を使用してネストされた親グループの変換も考慮
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

      # ---- Step 2〜4: Undo ラップ → カッターボックス生成 → subtract ----
      # NOTE: start_operation を build_half_space_cutter より前に置くことで、
      #       生成途中や演算失敗時に abort_operation だけで一時カッターが確実に消える。
      model.start_operation('Trim Solid', true)
      half_space = nil

      begin
        # カット平面の法線方向（削除側）へ延伸するカッターボックスを生成
        half_space = build_half_space_cutter(
          model,
          cut_info[:center],
          cut_info[:normal],
          target,
          click_pt
        )
        raise 'ハーフスペースカッターの生成に失敗しました' if half_space.nil?

        puts '[TrimTool] execute_trim: half_space.subtract(target) 実行中...'

        # NOTE: subtract のレシーバ = カッター（half_space）、引数 = 削られるターゲット。
        #       戻り値はトリム済みの target（完成品）。cutter（half_space）は API が自動削除。
        #       @cutter はこの演算に渡さないため保持される（連続トリム可能）。
        result     = half_space.subtract(target)
        half_space = nil  # subtract 成功時は cutter（half_space）が API により自動削除済み

        raise 'ブーリアン演算が失敗しました（ソリッドが非マニフォールドの可能性があります）' if result.nil?

        # subtract 成功後に共面エッジを除去（カット断面の不要な分割線をクリーンアップ）
        cleanup_coplanar_edges(result)

        model.commit_operation
        puts "[TrimTool] execute_trim: 完了 result=#{entity_label(result)}"

        # STATE 1 を維持して同じカッターで連続トリムを可能にする
        @hovered          = nil
        @hovered_intersects = false
        @preview_cut_info = nil
        @hover_pt         = nil
        Sketchup.status_text = 'トリム完了。引き続き同じカッターで別の端部をトリムできます。ESC でカッター再選択。'

      rescue RuntimeError => e
        # abort_operation により操作内のすべての変更（half_space 生成を含む）がロールバックされる
        model.abort_operation
        half_space = nil
        puts "[TrimTool] execute_trim エラー: #{e.message}"
        UI.messagebox("トリム失敗：\n#{e.message}", MB_OK)
      end

      view.invalidate
    end

    # ----------------------------------------------------------------
    # カット平面の特定
    #
    # カッターソリッドのフェイス群を走査し、以下の条件を満たすフェイスを選択:
    #   plane_n.dot(click_pt - plane_pt) > 0
    #   （フェイス法線がクリック点方向を向く = 削除側の境界面）
    # 条件を満たす候補の中からクリック点に最も近いフェイスを返す。
    #
    # cutter_transform: カッターのグローバル変換行列（nil の場合は cutter.transformation を使用）
    #   ネストされた親グループがある場合に pick_solid_with_transform で取得した累積変換を渡す。
    # quiet: true にすると puts を抑制する（onMouseMove からの連続呼び出し用）
    #
    # @return [Hash] { center: Geom::Point3d, normal: Geom::Vector3d, dot: Float } or nil
    # ----------------------------------------------------------------
    def find_cut_face(cutter, click_pt, cutter_transform: nil, quiet: false)
      entities  = cutter.is_a?(Sketchup::Group) ? cutter.entities : cutter.definition.entities
      # グローバル変換が渡された場合はそれを優先（ネスト対応）
      # nil の場合は entity.transformation にフォールバック
      transform = cutter_transform || cutter.transformation

      best      = nil
      best_dist = Float::INFINITY

      entities.grep(Sketchup::Face).each do |face|
        # フェイスの中心と法線をワールド座標に変換
        center_world = face.bounds.center.transform(transform)
        normal_world = face.normal.transform(transform)
        normal_world.normalize!

        # 内積による方向判定:
        # dot = plane_n · (click_pt - plane_pt)
        # 正値 → フェイス法線がクリック点方向を向く → 削除側の境界面
        dot = normal_world.dot(click_pt - center_world)
        next if dot <= 0.0

        dist = center_world.distance(click_pt)
        if dist < best_dist
          best_dist = dist
          best = { center: center_world, normal: normal_world, dot: dot }
        end
      end

      unless quiet
        face_count = entities.grep(Sketchup::Face).count
        puts "[TrimTool] find_cut_face: #{best ? '検出成功' : '候補なし'} " \
             "(フェイス数=#{face_count})"
      end
      best
    end

    # ----------------------------------------------------------------
    # ハーフスペースカッターボックスの生成
    #
    # カット平面（plane_pt, plane_n）から削除側（plane_n 方向）へ延伸する
    # 直方体ソリッドグループを生成して返す。
    #
    # 延伸距離の動的決定:
    #   dot = plane_n.dot(click_pt - plane_pt) → カット平面からクリック点までの射影距離
    #   extend_dist = max(dot * 2 + 5m, target対角線 * 3 + 10m)
    #   これにより T字・貫通どちらの交差形状にも対応できる。
    #
    # @return [Sketchup::Group] カッターボックス、または nil（失敗時）
    # ----------------------------------------------------------------
    def build_half_space_cutter(model, plane_pt, plane_n, target, click_pt)
      bb = target.bounds

      # 内積による延伸方向の確認と延伸距離の動的決定
      # dot = plane_n · (click_pt - plane_pt)
      # 正値であることは find_cut_face で保証済みだが、安全弁として反転チェックを行う
      dot = plane_n.dot(click_pt - plane_pt)
      if dot <= 0.0
        puts "[TrimTool] build_half_space_cutter: 警告 dot=#{dot.round(4)}, 法線を反転"
        plane_n.reverse!
        dot = -dot
      end

      # 延伸距離: クリック点までの射影距離の2倍 + target全体をカバーする保険距離
      target_diag = bb.min.distance(bb.max)
      extend_dist = [dot * 2 + 5.m, target_diag * 3 + 10.m].max
      # 底面サイズ: target の対角線の3倍（切断面が確実に target 全断面を覆う）
      half_size   = [target_diag * 3, 5.m].max

      # plane_n に垂直な 2 軸ベクトルを取得（底面の正方形を定義するため）
      # axes は [x_axis, y_axis, z_axis] を返す。インデックス 0, 1 が plane_n に直交する単位ベクトル。
      axes  = plane_n.axes
      perp1 = axes[0]
      perp2 = axes[1]
      perp1.length = half_size
      perp2.length = half_size

      # カット平面上の大きな正方形の 4 頂点
      # ※ 新グループは単位変換（origin）で生成されるため、ワールド座標 = ローカル座標
      pts = [
        plane_pt.offset(perp1).offset(perp2),
        plane_pt.offset(perp1.reverse).offset(perp2),
        plane_pt.offset(perp1.reverse).offset(perp2.reverse),
        plane_pt.offset(perp1).offset(perp2.reverse),
      ]

      g    = model.active_entities.add_group
      face = g.entities.add_face(pts)

      # フェイス法線を plane_n（削除側）に揃える
      face.reverse! if face.normal.dot(plane_n) < 0

      # plane_n 方向（削除側）へ extend_dist 分押し出してソリッドボックスを完成
      face.pushpull(extend_dist)

      puts "[TrimTool] build_half_space_cutter: 完了 " \
           "dot=#{dot.round(2)} " \
           "extend_dist=#{extend_dist.to_f.round(1)}in " \
           "half_size=#{half_size.to_f.round(1)}in"
      g

    rescue StandardError => e
      puts "[TrimTool] build_half_space_cutter エラー: #{e.message}"
      g.erase! if g&.valid?
      nil
    end

    # ----------------------------------------------------------------
    # PickHelper からソリッドエンティティと「ワールド変換行列」を取得
    #
    # ネスト（入れ子）対応:
    #   PickHelper の各パスを走査し、パスの末尾側（最内）にある
    #   Group/ComponentInstance を採用する。
    #   変換はルートから solid_path_idx までの transformation を手動で累積し
    #   ワールド座標への正確な変換行列を生成する。
    #   これにより親グループ内にあるコンポーネントでも正確なワールド座標が得られる。
    #
    # @return [Array(entity, Geom::Transformation)] エンティティとワールド変換
    #         エンティティが見つからない場合は [nil, nil]
    # ----------------------------------------------------------------
    def pick_solid_with_transform(ph)
      0.upto(ph.count - 1) do |i|
        path = ph.path_at(i)
        next unless path && !path.empty?

        # パス内で最も内側（末尾側）の Group/ComponentInstance のインデックスを特定
        solid_path_idx = nil
        path.each_with_index do |e, j|
          solid_path_idx = j if e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
        end
        next unless solid_path_idx

        # ルートから solid_path_idx まで全変換を累積してグローバル変換を算出
        # （1段ネスト: parent.transform × child.transform、深くネストされた場合も同様）
        world_tf = Geom::Transformation.new  # identity（単位行列）
        0.upto(solid_path_idx) do |j|
          e = path[j]
          world_tf = world_tf * e.transformation if e.respond_to?(:transformation)
        end

        return [path[solid_path_idx], world_tf]
      end

      [nil, nil]
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
    # BoundingBox のエッジをワイヤーフレームで単色描画（draw 内専用）
    # ----------------------------------------------------------------
    def draw_highlight(view, entity, color, line_width)
      return unless entity&.valid?

      corners = (0..7).map { |i| entity.bounds.corner(i) }
      pts     = []
      BB_EDGES.each { |a_idx, b_idx| pts << corners[a_idx] << corners[b_idx] }

      view.line_width    = line_width
      view.drawing_color = color
      view.draw(GL_LINES, pts)
    end

    # ----------------------------------------------------------------
    # カット平面プレビュー描画
    #
    # ターゲット BB をグレー細線で描画し、カット境界位置を半透明赤ポリゴン＋アウトラインで可視化。
    # 「箱の色分け」ではなく「どこで切れるか（刃の位置）」を直接表現する。
    #
    # カット平面ポリゴンのサイズ:
    #   ターゲット BB 対角線 × 0.7 を半径として正方形ポリゴンを生成。
    #   build_half_space_cutter と同じ perp 軸算出ロジックを使用。
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

      # ③ 半透明赤ポリゴン（カット境界面）
      view.drawing_color = COLOR_CUT_PLANE_FILL
      view.draw(GL_POLYGON, pts)

      # ④ 不透明赤アウトライン（ポリゴン縁取り）
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
    # 共面エッジのクリーンアップ
    #
    # ブーリアン演算（subtract）後、カット断面に生じる不要な分割エッジを除去する。
    # 「同一平面上にある隣接フェイスの境界エッジ」＝「共面エッジ」を検出して削除。
    #
    # 共面エッジの判定条件（AND）:
    #   1. フェイスを 2 つ持つエッジ（境界エッジのみ対象）
    #   2. 両フェイスの法線が平行（外積の長さ < 1e-8）
    #   3. f2 の代表頂点が f1 の平面方程式を満たす（距離 < 1e-6 inch）
    #
    # SketchUp の erase! は隣接フェイスをマージするため、
    # 削除後のジオメトリは自動的に統合された大きなフェイスになる。
    # ----------------------------------------------------------------
    def cleanup_coplanar_edges(entity)
      return unless entity&.valid?

      ents = entity.is_a?(Sketchup::Group) ? entity.entities : entity.definition.entities

      to_delete = ents.grep(Sketchup::Edge).select do |edge|
        next false unless edge.valid? && edge.faces.length == 2

        f1, f2 = edge.faces
        # 条件1: 法線が平行（外積 ≒ 0 → sin(θ) ≒ 0 → θ ≒ 0°）
        next false if f1.normal.cross(f2.normal).length > 1e-8

        # 条件2: 同一平面上（f2の頂点がf1の平面方程式を満たす）
        plane = f1.plane
        pt    = f2.vertices.first.position
        (plane[0] * pt.x + plane[1] * pt.y + plane[2] * pt.z + plane[3]).abs < 1e-6
      end

      to_delete.each { |e| e.erase! if e.valid? }
      puts "[TrimTool] cleanup_coplanar_edges: #{to_delete.length} 個の共面エッジを削除"
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

    # デバッグ用エンティティ情報文字列
    def entity_label(entity)
      return 'nil' unless entity

      type     = entity.is_a?(Sketchup::Group) ? 'Group' : 'Component'
      is_solid = entity.valid? ? manifold?(entity).to_s : 'invalid'
      "#{type}(id=#{entity.object_id}, manifold=#{is_solid})"
    end
  end
end

# frozen_string_literal: true

# su_smart_framing_tools/core/geometry_helper.rb
#
# Smart Framing Tools – 幾何学処理の共通モジュール
#
# 各ツールクラスが `include SuSmartFramingTools::GeometryHelper` することで
# 以下の機能を再利用できる:
#
#   - pick_solid_with_transform : PickHelper からネスト対応グローバル変換付きでソリッドを取得
#   - find_cut_face             : カット平面の特定（内積による方向判定）
#   - build_half_space_cutter   : ハーフスペースカッターボックスの生成
#   - cleanup_coplanar_edges    : ブーリアン演算後の共面エッジ除去
#   - draw_highlight            : BoundingBox ワイヤーフレーム単色描画
#   - manifold?                 : ソリッド（マニフォールド）判定
#   - bounding_boxes_intersect? : AABB による高速交差判定
#   - entity_label              : デバッグ用エンティティ情報文字列

module SuSmartFramingTools
  module GeometryHelper
    # BoundingBox の 12 辺（corners インデックスペア）
    # draw_highlight と各ツールの描画処理で共用する
    BB_EDGES = [
      [0, 1], [1, 3], [3, 2], [2, 0],  # 底面
      [4, 5], [5, 7], [7, 6], [6, 4],  # 上面
      [0, 4], [1, 5], [2, 6], [3, 7]   # 垂直辺
    ].freeze

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
    # BoundingBox のエッジをワイヤーフレームで単色描画（draw コールバック内専用）
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
    # デバッグ用エンティティ情報文字列
    # ----------------------------------------------------------------
    def entity_label(entity)
      return 'nil' unless entity

      type     = entity.is_a?(Sketchup::Group) ? 'Group' : 'Component'
      is_solid = entity.valid? ? manifold?(entity).to_s : 'invalid'
      "#{type}(id=#{entity.object_id}, manifold=#{is_solid})"
    end

    private

    # ----------------------------------------------------------------
    # カット平面の特定
    #
    # カッターソリッドのフェイス群を走査し、以下の条件を満たすフェイスを選択:
    #   plane_n.dot(click_pt - plane_pt) > 0
    #   （フェイス法線がクリック点方向を向く = 削除側の境界面）
    #
    # 選定スコア（小口優先）:
    #   部材の長手方向（バウンディングボックスの最長軸）に法線が揃っている面
    #   ＝ 小口（端面）を優先的に選択する。
    #   adjusted_dist = dist / (1 + endface_score * 3)
    #   endface_score = |normal · long_axis|（端面ほど 1 に近い）
    #   これにより端面は最大 4 倍「近く」評価され、長手側面より優先される。
    #
    # cutter_transform: カッターのグローバル変換行列（nil の場合は cutter.transformation を使用）
    # quiet: true にすると puts を抑制する（onMouseMove からの連続呼び出し用）
    #
    # @return [Hash] { center: Geom::Point3d, normal: Geom::Vector3d, dot: Float } or nil
    # ----------------------------------------------------------------
    def find_cut_face(cutter, click_pt, cutter_transform: nil, quiet: false)
      entities  = cutter.is_a?(Sketchup::Group) ? cutter.entities : cutter.definition.entities
      transform = cutter_transform || cutter.transformation

      # 部材の長手方向（世界座標系 AABB の最長軸）を特定
      bb = cutter.bounds
      long_axis = [[bb.width,  Geom::Vector3d.new(1, 0, 0)],
                   [bb.height, Geom::Vector3d.new(0, 1, 0)],
                   [bb.depth,  Geom::Vector3d.new(0, 0, 1)]].max_by { |size, _| size }[1]

      best       = nil
      best_score = Float::INFINITY

      entities.grep(Sketchup::Face).each do |face|
        center_world = face.bounds.center.transform(transform)
        normal_world = face.normal.transform(transform)
        normal_world.normalize!

        dot = normal_world.dot(click_pt - center_world)
        next if dot < -1e-6

        dist = center_world.distance(click_pt)
        # 小口スコア: 法線が長手軸と平行なほど 1 に近い（端面 = 1、長手側面 ≈ 0）
        endface_score = normal_world.dot(long_axis).abs
        # 小口優先の調整距離: 端面は最大 4x 近く評価される
        adjusted_dist = dist / (1.0 + endface_score * 3.0)

        if adjusted_dist < best_score
          best_score = adjusted_dist
          best = { center: center_world, normal: normal_world, dot: dot }
        end
      end

      unless quiet
        face_count = entities.grep(Sketchup::Face).count
        puts "[GeometryHelper] find_cut_face: #{best ? '検出成功' : '候補なし'} " \
             "(フェイス数=#{face_count})"
      end
      best
    end

    # ----------------------------------------------------------------
    # カット面の Sketchup::Face オブジェクトを返す（find_cut_face の Face 返し版）
    #
    # find_cut_face と同じ小口優先スコアリングで Face オブジェクトを返す。
    # make_unique 後に有効な Face 参照を取得するために使用する。
    #
    # @return [Sketchup::Face, nil]
    # ----------------------------------------------------------------
    def find_cut_face_object(entity, click_pt, entity_transform: nil)
      ents      = entity.is_a?(Sketchup::Group) ? entity.entities : entity.definition.entities
      transform = entity_transform || entity.transformation

      bb = entity.bounds
      long_axis = [[bb.width,  Geom::Vector3d.new(1, 0, 0)],
                   [bb.height, Geom::Vector3d.new(0, 1, 0)],
                   [bb.depth,  Geom::Vector3d.new(0, 0, 1)]].max_by { |size, _| size }[1]

      best_face  = nil
      best_score = Float::INFINITY

      ents.grep(Sketchup::Face).each do |face|
        center_world = face.bounds.center.transform(transform)
        normal_world = face.normal.transform(transform)
        normal_world.normalize!

        dot = normal_world.dot(click_pt - center_world)
        next if dot < -1e-6

        dist          = center_world.distance(click_pt)
        endface_score = normal_world.dot(long_axis).abs
        adjusted_dist = dist / (1.0 + endface_score * 3.0)

        if adjusted_dist < best_score
          best_score = adjusted_dist
          best_face  = face
        end
      end

      best_face
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
      dot = plane_n.dot(click_pt - plane_pt)
      if dot <= 0.0
        puts "[GeometryHelper] build_half_space_cutter: 警告 dot=#{dot.round(4)}, 法線を反転"
        plane_n.reverse!
        dot = -dot
      end

      # 延伸距離: クリック点までの射影距離の2倍 + target全体をカバーする保険距離
      target_diag = bb.min.distance(bb.max)
      extend_dist = [dot * 2 + 5.m, target_diag * 3 + 10.m].max
      half_size   = [target_diag * 3, 5.m].max

      # plane_n に垂直な 2 軸ベクトルを取得（底面の正方形を定義するため）
      axes  = plane_n.axes
      perp1 = axes[0]; perp1.length = half_size
      perp2 = axes[1]; perp2.length = half_size

      # カット平面上の大きな正方形の 4 頂点
      pts = [
        plane_pt.offset(perp1).offset(perp2),
        plane_pt.offset(perp1.reverse).offset(perp2),
        plane_pt.offset(perp1.reverse).offset(perp2.reverse),
        plane_pt.offset(perp1).offset(perp2.reverse),
      ]

      g    = model.active_entities.add_group
      face = g.entities.add_face(pts)
      face.reverse! if face.normal.dot(plane_n) < 0
      face.pushpull(extend_dist)

      puts "[GeometryHelper] build_half_space_cutter: 完了 " \
           "dot=#{dot.round(2)} " \
           "extend_dist=#{extend_dist.to_f.round(1)}in " \
           "half_size=#{half_size.to_f.round(1)}in"
      g

    rescue StandardError => e
      puts "[GeometryHelper] build_half_space_cutter エラー: #{e.message}"
      g.erase! if g&.valid?
      nil
    end

    # ----------------------------------------------------------------
    # 共面エッジのクリーンアップ
    #
    # ブーリアン演算（subtract）後、カット断面に生じる不要な分割エッジを除去する。
    # 「同一平面上にある隣接フェイスの境界エッジ」を検出して削除。
    #
    # 共面エッジの判定条件（AND）:
    #   1. フェイスを 2 つ持つエッジ（境界エッジのみ対象）
    #   2. 両フェイスの法線が平行（外積の長さ < 1e-8）
    #   3. f2 の代表頂点が f1 の平面方程式を満たす（距離 < 1e-6 inch）
    # ----------------------------------------------------------------
    def cleanup_coplanar_edges(entity)
      return unless entity&.valid?

      ents = entity.is_a?(Sketchup::Group) ? entity.entities : entity.definition.entities

      to_delete = ents.grep(Sketchup::Edge).select do |edge|
        next false unless edge.valid? && edge.faces.length == 2

        f1, f2 = edge.faces
        next false if f1.normal.cross(f2.normal).length > 1e-8

        plane = f1.plane
        pt    = f2.vertices.first.position
        (plane[0] * pt.x + plane[1] * pt.y + plane[2] * pt.z + plane[3]).abs < 1e-6
      end

      to_delete.each { |e| e.erase! if e.valid? }
      puts "[GeometryHelper] cleanup_coplanar_edges: #{to_delete.length} 個の共面エッジを削除"
    end
  end
end

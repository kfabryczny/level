defmodule LevelWeb.GraphQL.CreatePostReactionTest do
  use LevelWeb.ConnCase, async: true
  import LevelWeb.GraphQL.TestHelpers

  alias Level.Posts

  @query """
    mutation CreatePostReaction(
      $space_id: ID!,
      $post_id: ID!
    ) {
      createPostReaction(
        spaceId: $space_id,
        postId: $post_id,
        value: "👍"
      ) {
        success
        post {
          id
        }
        errors {
          attribute
          message
        }
      }
    }
  """

  setup %{conn: conn} do
    {:ok, %{user: user, space: space, space_user: space_user}} = create_user_and_space()
    conn = authenticate_with_jwt(conn, user)
    {:ok, %{conn: conn, user: user, space: space, space_user: space_user}}
  end

  test "creates a reaction", %{conn: conn, space: space, space_user: space_user} do
    {:ok, %{group: group}} = create_group(space_user)
    {:ok, %{post: post}} = create_post(space_user, group)

    variables = %{space_id: space.id, post_id: post.id}

    conn =
      conn
      |> put_graphql_headers()
      |> post("/graphql", %{query: @query, variables: variables})

    assert json_response(conn, 200) == %{
             "data" => %{
               "createPostReaction" => %{
                 "success" => true,
                 "post" => %{
                   "id" => post.id
                 },
                 "errors" => []
               }
             }
           }

    assert Posts.reacted?(space_user, post)
  end
end

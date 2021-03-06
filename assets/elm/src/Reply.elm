module Reply exposing (Reply, author, body, bodyHtml, canEdit, decoder, files, fragment, hasReacted, hasViewed, id, notDeleted, postId, postedAt, reactionCount, reactorIds)

import Author exposing (Author)
import File exposing (File)
import GraphQL exposing (Fragment)
import Id exposing (Id)
import Json.Decode as Decode exposing (Decoder, bool, field, int, string)
import Json.Decode.Pipeline as Pipeline exposing (custom, required)
import Time exposing (Posix)
import Util exposing (dateDecoder)



-- TYPES


type Reply
    = Reply Data


type alias Data =
    { id : String
    , postId : String
    , body : String
    , bodyHtml : String
    , author : Author
    , files : List File
    , hasViewed : Bool
    , hasReacted : Bool
    , reactionCount : Int
    , reactorIds : List Id
    , isDeleted : Bool
    , canEdit : Bool
    , postedAt : Posix
    , fetchedAt : Int
    }


fragment : Fragment
fragment =
    GraphQL.toFragment
        """
        fragment ReplyFields on Reply {
          id
          postId
          body
          bodyHtml
          author {
            ...AuthorFields
          }
          files {
            ...FileFields
          }
          hasViewed
          hasReacted
          reactions(first: 100) {
            edges {
              node {
                spaceUser {
                  ...SpaceUserFields
                }
              }
            }
            totalCount
          }
          isDeleted
          canEdit
          postedAt
          fetchedAt
        }
        """
        [ Author.fragment
        , File.fragment
        ]



-- ACCESSORS


id : Reply -> Id
id (Reply data) =
    data.id


postId : Reply -> Id
postId (Reply data) =
    data.postId


body : Reply -> String
body (Reply data) =
    data.body


bodyHtml : Reply -> String
bodyHtml (Reply data) =
    data.bodyHtml


author : Reply -> Author
author (Reply data) =
    data.author


files : Reply -> List File
files (Reply data) =
    data.files


hasViewed : Reply -> Bool
hasViewed (Reply data) =
    data.hasViewed


hasReacted : Reply -> Bool
hasReacted (Reply data) =
    data.hasReacted


reactionCount : Reply -> Int
reactionCount (Reply data) =
    data.reactionCount


reactorIds : Reply -> List Id
reactorIds (Reply data) =
    data.reactorIds


notDeleted : Reply -> Bool
notDeleted (Reply data) =
    not data.isDeleted


canEdit : Reply -> Bool
canEdit (Reply data) =
    data.canEdit


postedAt : Reply -> Posix
postedAt (Reply data) =
    data.postedAt



-- DECODERS


decoder : Decoder Reply
decoder =
    Decode.map Reply <|
        (Decode.succeed Data
            |> required "id" Id.decoder
            |> required "postId" Id.decoder
            |> required "body" string
            |> required "bodyHtml" string
            |> required "author" Author.decoder
            |> required "files" (Decode.list File.decoder)
            |> required "hasViewed" bool
            |> required "hasReacted" bool
            |> custom (Decode.at [ "reactions", "totalCount" ] int)
            |> custom (Decode.at [ "reactions", "edges" ] (Decode.list <| Decode.at [ "node", "spaceUser", "id" ] Id.decoder))
            |> required "isDeleted" bool
            |> required "canEdit" bool
            |> required "postedAt" dateDecoder
            |> required "fetchedAt" int
        )

module Page.Group exposing (Model, Msg(..), consumeEvent, consumeKeyboardEvent, init, setup, subscriptions, teardown, title, update, view)

import Avatar exposing (personAvatar)
import Component.Post
import Connection exposing (Connection)
import Device exposing (Device)
import Event exposing (Event)
import FieldEditor exposing (FieldEditor)
import File exposing (File)
import Flash
import Globals exposing (Globals)
import Group exposing (Group)
import GroupMembership exposing (GroupMembership, GroupMembershipState(..))
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (..)
import Icons
import Id exposing (Id)
import Json.Decode as Decode
import KeyboardShortcuts exposing (Modifier(..))
import Layout.SpaceDesktop
import Layout.SpaceMobile
import ListHelpers exposing (insertUniqueBy, removeBy)
import Mutation.BookmarkGroup as BookmarkGroup
import Mutation.CloseGroup as CloseGroup
import Mutation.ClosePost as ClosePost
import Mutation.CreatePost as CreatePost
import Mutation.DismissPosts as DismissPosts
import Mutation.MarkAsRead as MarkAsRead
import Mutation.ReopenGroup as ReopenGroup
import Mutation.SubscribeToGroup as SubscribeToGroup
import Mutation.UnbookmarkGroup as UnbookmarkGroup
import Mutation.UnsubscribeFromGroup as UnsubscribeFromGroup
import Mutation.UpdateGroup as UpdateGroup
import Mutation.WatchGroup as WatchGroup
import Pagination
import Post exposing (Post)
import PostEditor exposing (PostEditor)
import PushStatus
import Query.FeaturedMemberships as FeaturedMemberships
import Query.GroupInit as GroupInit
import Reply exposing (Reply)
import Repo exposing (Repo)
import ResolvedPostWithReplies exposing (ResolvedPostWithReplies)
import Route exposing (Route)
import Route.Group exposing (Params(..))
import Route.GroupSettings
import Route.NewGroupPost
import Route.Search
import Route.SpaceUser
import Scroll
import ServiceWorker
import Session exposing (Session)
import Space exposing (Space)
import SpaceUser exposing (SpaceUser)
import Subscription.GroupSubscription as GroupSubscription
import Task exposing (Task)
import TaskHelpers
import Time exposing (Posix, Zone, every)
import ValidationError exposing (ValidationError)
import Vendor.Keys as Keys exposing (enter, esc, onKeydown, preventDefault)
import View.Helpers exposing (selectValue, setFocus, smartFormatTime, viewIf, viewUnless)
import View.SearchBox



-- MODEL


type alias Model =
    { params : Params
    , viewerId : Id
    , spaceId : Id
    , groupId : Id
    , featuredMemberIds : List Id
    , postComps : Connection Component.Post.Model
    , now : ( Zone, Posix )
    , nameEditor : FieldEditor String
    , postComposer : PostEditor
    , searchEditor : FieldEditor String
    , isWatching : Bool
    , isTogglingWatching : Bool

    -- MOBILE
    , showNav : Bool
    , showSidebar : Bool
    }


type alias Data =
    { viewer : SpaceUser
    , space : Space
    , group : Group
    , featuredMembers : List SpaceUser
    }


resolveData : Repo -> Model -> Maybe Data
resolveData repo model =
    Maybe.map4 Data
        (Repo.getSpaceUser model.viewerId repo)
        (Repo.getSpace model.spaceId repo)
        (Repo.getGroup model.groupId repo)
        (Just <| Repo.getSpaceUsers model.featuredMemberIds repo)



-- PAGE PROPERTIES


title : Repo -> Model -> String
title repo model =
    case Repo.getGroup model.groupId repo of
        Just group ->
            "#" ++ Group.name group

        Nothing ->
            "Group"



-- LIFECYCLE


init : Params -> Globals -> Task Session.Error ( Globals, Model )
init params globals =
    globals.session
        |> GroupInit.request params 10
        |> TaskHelpers.andThenGetCurrentTime
        |> Task.map (buildModel params globals)


buildModel : Params -> Globals -> ( ( Session, GroupInit.Response ), ( Zone, Posix ) ) -> ( Globals, Model )
buildModel params globals ( ( newSession, resp ), now ) =
    let
        postComps =
            Connection.map (buildPostComponent resp.spaceId) resp.postWithRepliesIds

        model =
            Model
                params
                resp.viewerId
                resp.spaceId
                resp.groupId
                resp.featuredMemberIds
                postComps
                now
                (FieldEditor.init "name-editor" "")
                (PostEditor.init ("post-composer-" ++ resp.groupId))
                (FieldEditor.init "search-editor" "")
                resp.isWatching
                False
                False
                False

        newRepo =
            Repo.union resp.repo globals.repo
    in
    ( { globals | session = newSession, repo = newRepo }, model )


buildPostComponent : Id -> ( Id, Connection Id ) -> Component.Post.Model
buildPostComponent spaceId ( postId, replyIds ) =
    Component.Post.init spaceId postId replyIds


setup : Globals -> Model -> Cmd Msg
setup globals model =
    let
        pageCmd =
            Cmd.batch
                [ setupSockets model.groupId
                , PostEditor.fetchLocal model.postComposer
                ]

        postsCmd =
            Connection.toList model.postComps
                |> List.map (\post -> Cmd.map (PostComponentMsg post.id) (Component.Post.setup globals post))
                |> Cmd.batch
    in
    Cmd.batch
        [ pageCmd
        , postsCmd
        , Scroll.toDocumentTop NoOp
        ]


teardown : Globals -> Model -> Cmd Msg
teardown globals model =
    let
        pageCmd =
            teardownSockets model.groupId

        postsCmd =
            Connection.toList model.postComps
                |> List.map (\post -> Cmd.map (PostComponentMsg post.id) (Component.Post.teardown globals post))
                |> Cmd.batch
    in
    Cmd.batch [ pageCmd, postsCmd ]


setupSockets : Id -> Cmd Msg
setupSockets groupId =
    GroupSubscription.subscribe groupId


teardownSockets : Id -> Cmd Msg
teardownSockets groupId =
    GroupSubscription.unsubscribe groupId



-- UPDATE


type Msg
    = NoOp
    | ToggleKeyboardCommands
    | Tick Posix
    | SetCurrentTime Posix Zone
    | PostEditorEventReceived Decode.Value
    | NewPostBodyChanged String
    | NewPostFileAdded File
    | NewPostFileUploadProgress Id Int
    | NewPostFileUploaded Id Id String
    | NewPostFileUploadError Id
    | ToggleUrgent
    | NewPostSubmit
    | NewPostSubmitted (Result Session.Error ( Session, CreatePost.Response ))
    | ToggleWatching
    | SubscribeClicked
    | Subscribed (Result Session.Error ( Session, SubscribeToGroup.Response ))
    | UnsubscribeClicked
    | Unsubscribed (Result Session.Error ( Session, UnsubscribeFromGroup.Response ))
    | WatchClicked
    | Watched (Result Session.Error ( Session, WatchGroup.Response ))
    | NameClicked
    | NameEditorChanged String
    | NameEditorDismissed
    | NameEditorSubmit
    | NameEditorSubmitted (Result Session.Error ( Session, UpdateGroup.Response ))
    | FeaturedMembershipsRefreshed (Result Session.Error ( Session, FeaturedMemberships.Response ))
    | PostComponentMsg String Component.Post.Msg
    | Bookmark
    | Bookmarked (Result Session.Error ( Session, BookmarkGroup.Response ))
    | Unbookmark
    | Unbookmarked (Result Session.Error ( Session, UnbookmarkGroup.Response ))
    | PrivacyToggle Bool
    | PrivacyToggled (Result Session.Error ( Session, UpdateGroup.Response ))
    | ExpandSearchEditor
    | CollapseSearchEditor
    | SearchEditorChanged String
    | SearchSubmitted
    | CloseClicked
    | Closed (Result Session.Error ( Session, CloseGroup.Response ))
    | ReopenClicked
    | Reopened (Result Session.Error ( Session, ReopenGroup.Response ))
    | PostsDismissed (Result Session.Error ( Session, DismissPosts.Response ))
    | PostsMarkedAsRead (Result Session.Error ( Session, MarkAsRead.Response ))
    | PostClosed (Result Session.Error ( Session, ClosePost.Response ))
    | PostSelected Id
    | FocusOnComposer
    | PushSubscribeClicked
      -- MOBILE
    | NavToggled
    | SidebarToggled
    | ScrollTopClicked


update : Msg -> Globals -> Model -> ( ( Model, Cmd Msg ), Globals )
update msg globals model =
    case msg of
        NoOp ->
            noCmd globals model

        ToggleKeyboardCommands ->
            ( ( model, Cmd.none ), { globals | showKeyboardCommands = not globals.showKeyboardCommands } )

        Tick posix ->
            ( ( model, Task.perform (SetCurrentTime posix) Time.here ), globals )

        SetCurrentTime posix zone ->
            noCmd globals { model | now = ( zone, posix ) }

        PostEditorEventReceived value ->
            case PostEditor.decodeEvent value of
                PostEditor.LocalDataFetched id body ->
                    if id == PostEditor.getId model.postComposer then
                        let
                            newPostComposer =
                                PostEditor.setBody body model.postComposer
                        in
                        ( ( { model | postComposer = newPostComposer }
                          , Cmd.none
                          )
                        , globals
                        )

                    else
                        noCmd globals model

                PostEditor.Unknown ->
                    noCmd globals model

        NewPostBodyChanged value ->
            let
                newPostComposer =
                    PostEditor.setBody value model.postComposer
            in
            ( ( { model | postComposer = newPostComposer }
              , PostEditor.saveLocal newPostComposer
              )
            , globals
            )

        NewPostFileAdded file ->
            noCmd globals { model | postComposer = PostEditor.addFile file model.postComposer }

        NewPostFileUploadProgress clientId percentage ->
            noCmd globals { model | postComposer = PostEditor.setFileUploadPercentage clientId percentage model.postComposer }

        NewPostFileUploaded clientId fileId url ->
            let
                newPostComposer =
                    model.postComposer
                        |> PostEditor.setFileState clientId (File.Uploaded fileId url)

                cmd =
                    newPostComposer
                        |> PostEditor.insertFileLink fileId
            in
            ( ( { model | postComposer = newPostComposer }, cmd ), globals )

        NewPostFileUploadError clientId ->
            noCmd globals { model | postComposer = PostEditor.setFileState clientId File.UploadError model.postComposer }

        ToggleUrgent ->
            ( ( { model | postComposer = PostEditor.toggleIsUrgent model.postComposer }, Cmd.none ), globals )

        NewPostSubmit ->
            if PostEditor.isSubmittable model.postComposer then
                let
                    variables =
                        CreatePost.variablesWithGroup
                            model.spaceId
                            model.groupId
                            (PostEditor.getBody model.postComposer)
                            (PostEditor.getUploadIds model.postComposer)
                            (PostEditor.getIsUrgent model.postComposer)

                    cmd =
                        globals.session
                            |> CreatePost.request variables
                            |> Task.attempt NewPostSubmitted
                in
                ( ( { model | postComposer = PostEditor.setToSubmitting model.postComposer }, cmd ), globals )

            else
                noCmd globals model

        NewPostSubmitted (Ok ( newSession, response )) ->
            let
                ( newPostComposer, cmd ) =
                    model.postComposer
                        |> PostEditor.reset
            in
            ( ( { model | postComposer = newPostComposer }, cmd )
            , { globals | session = newSession }
            )

        NewPostSubmitted (Err Session.Expired) ->
            redirectToLogin globals model

        NewPostSubmitted (Err _) ->
            { model | postComposer = PostEditor.setNotSubmitting model.postComposer }
                |> noCmd globals

        ToggleWatching ->
            let
                cmd =
                    if model.isWatching then
                        globals.session
                            |> SubscribeToGroup.request model.spaceId model.groupId
                            |> Task.attempt Subscribed

                    else
                        globals.session
                            |> WatchGroup.request model.spaceId model.groupId
                            |> Task.attempt Watched
            in
            ( ( { model | isWatching = not model.isWatching, isTogglingWatching = True }, cmd ), globals )

        SubscribeClicked ->
            let
                cmd =
                    globals.session
                        |> SubscribeToGroup.request model.spaceId model.groupId
                        |> Task.attempt Subscribed
            in
            ( ( model, cmd ), globals )

        Subscribed (Ok ( newSession, SubscribeToGroup.Success group )) ->
            let
                newRepo =
                    globals.repo
                        |> Repo.setGroup group
            in
            ( ( { model | isWatching = False, isTogglingWatching = False }, Cmd.none )
            , { globals | session = newSession, repo = newRepo }
            )

        Subscribed (Ok ( newSession, SubscribeToGroup.Invalid _ )) ->
            noCmd globals model

        Subscribed (Err Session.Expired) ->
            redirectToLogin globals model

        Subscribed (Err _) ->
            noCmd globals model

        UnsubscribeClicked ->
            let
                cmd =
                    globals.session
                        |> UnsubscribeFromGroup.request model.spaceId model.groupId
                        |> Task.attempt Unsubscribed
            in
            ( ( { model | isWatching = False, isTogglingWatching = False }, cmd ), globals )

        Unsubscribed (Ok ( newSession, UnsubscribeFromGroup.Success group )) ->
            let
                newRepo =
                    globals.repo
                        |> Repo.setGroup group
            in
            ( ( { model | isWatching = False, isTogglingWatching = False }, Cmd.none )
            , { globals | session = newSession, repo = newRepo }
            )

        Unsubscribed (Ok ( newSession, UnsubscribeFromGroup.Invalid _ )) ->
            noCmd globals model

        Unsubscribed (Err Session.Expired) ->
            redirectToLogin globals model

        Unsubscribed (Err _) ->
            noCmd globals model

        WatchClicked ->
            let
                cmd =
                    globals.session
                        |> WatchGroup.request model.spaceId model.groupId
                        |> Task.attempt Watched
            in
            ( ( { model | isWatching = True, isTogglingWatching = True }, cmd ), globals )

        Watched (Ok ( newSession, WatchGroup.Success group )) ->
            let
                newRepo =
                    globals.repo
                        |> Repo.setGroup group
            in
            ( ( { model | isWatching = True, isTogglingWatching = False }, Cmd.none )
            , { globals | session = newSession, repo = newRepo }
            )

        Watched (Ok ( newSession, WatchGroup.Invalid _ )) ->
            noCmd globals model

        Watched (Err Session.Expired) ->
            redirectToLogin globals model

        Watched (Err _) ->
            noCmd globals model

        NameClicked ->
            case resolveData globals.repo model of
                Just data ->
                    let
                        nodeId =
                            FieldEditor.getNodeId model.nameEditor

                        newNameEditor =
                            model.nameEditor
                                |> FieldEditor.expand
                                |> FieldEditor.setValue (Group.name data.group)
                                |> FieldEditor.setErrors []

                        cmd =
                            Cmd.batch
                                [ setFocus nodeId NoOp
                                , selectValue nodeId
                                ]
                    in
                    ( ( { model | nameEditor = newNameEditor }, cmd ), globals )

                Nothing ->
                    noCmd globals model

        NameEditorChanged val ->
            let
                newValue =
                    val
                        |> String.toLower
                        |> String.replace " " "-"

                newNameEditor =
                    model.nameEditor
                        |> FieldEditor.setValue newValue
            in
            noCmd globals { model | nameEditor = newNameEditor }

        NameEditorDismissed ->
            let
                newNameEditor =
                    model.nameEditor
                        |> FieldEditor.collapse
            in
            noCmd globals { model | nameEditor = newNameEditor }

        NameEditorSubmit ->
            let
                newNameEditor =
                    model.nameEditor
                        |> FieldEditor.setIsSubmitting True

                variables =
                    UpdateGroup.variables model.spaceId model.groupId (Just (FieldEditor.getValue newNameEditor)) Nothing

                cmd =
                    globals.session
                        |> UpdateGroup.request variables
                        |> Task.attempt NameEditorSubmitted
            in
            ( ( { model | nameEditor = newNameEditor }, cmd ), globals )

        NameEditorSubmitted (Ok ( newSession, UpdateGroup.Success newGroup )) ->
            let
                newNameEditor =
                    model.nameEditor
                        |> FieldEditor.collapse
                        |> FieldEditor.setIsSubmitting False

                newModel =
                    { model | nameEditor = newNameEditor }

                repo =
                    globals.repo
                        |> Repo.setGroup newGroup
            in
            noCmd { globals | session = newSession, repo = repo } newModel

        NameEditorSubmitted (Ok ( newSession, UpdateGroup.Invalid errors )) ->
            let
                newNameEditor =
                    model.nameEditor
                        |> FieldEditor.setErrors errors
                        |> FieldEditor.setIsSubmitting False
            in
            ( ( { model | nameEditor = newNameEditor }
              , selectValue (FieldEditor.getNodeId newNameEditor)
              )
            , { globals | session = newSession }
            )

        NameEditorSubmitted (Err Session.Expired) ->
            redirectToLogin globals model

        NameEditorSubmitted (Err _) ->
            let
                newNameEditor =
                    model.nameEditor
                        |> FieldEditor.setIsSubmitting False
                        |> FieldEditor.setErrors [ ValidationError "name" "Hmm, something went wrong." ]
            in
            ( ( { model | nameEditor = newNameEditor }, Cmd.none )
            , globals
            )

        FeaturedMembershipsRefreshed (Ok ( newSession, resp )) ->
            let
                newRepo =
                    Repo.union resp.repo globals.repo
            in
            ( ( { model | featuredMemberIds = resp.spaceUserIds }, Cmd.none )
            , { globals | session = newSession, repo = newRepo }
            )

        FeaturedMembershipsRefreshed (Err Session.Expired) ->
            redirectToLogin globals model

        FeaturedMembershipsRefreshed (Err _) ->
            noCmd globals model

        PostComponentMsg postId componentMsg ->
            case Connection.get .id postId model.postComps of
                Just postComp ->
                    let
                        ( ( newPostComp, cmd ), newGlobals ) =
                            Component.Post.update componentMsg globals postComp
                    in
                    ( ( { model | postComps = Connection.update .id newPostComp model.postComps }
                      , Cmd.map (PostComponentMsg postId) cmd
                      )
                    , newGlobals
                    )

                Nothing ->
                    noCmd globals model

        Bookmark ->
            let
                cmd =
                    globals.session
                        |> BookmarkGroup.request model.spaceId model.groupId
                        |> Task.attempt Bookmarked
            in
            ( ( model, cmd ), globals )

        Bookmarked (Ok ( newSession, _ )) ->
            noCmd { globals | session = newSession } model

        Bookmarked (Err Session.Expired) ->
            redirectToLogin globals model

        Bookmarked (Err _) ->
            noCmd globals model

        Unbookmark ->
            let
                cmd =
                    globals.session
                        |> UnbookmarkGroup.request model.spaceId model.groupId
                        |> Task.attempt Unbookmarked
            in
            ( ( model, cmd ), globals )

        Unbookmarked (Ok ( newSession, _ )) ->
            noCmd { globals | session = newSession } model

        Unbookmarked (Err Session.Expired) ->
            redirectToLogin globals model

        Unbookmarked (Err _) ->
            noCmd globals model

        PrivacyToggle isPrivate ->
            let
                variables =
                    UpdateGroup.variables model.spaceId model.groupId Nothing (Just isPrivate)

                cmd =
                    globals.session
                        |> UpdateGroup.request variables
                        |> Task.attempt PrivacyToggled
            in
            ( ( model, cmd ), globals )

        PrivacyToggled (Ok ( newSession, _ )) ->
            noCmd { globals | session = newSession } model

        PrivacyToggled (Err Session.Expired) ->
            redirectToLogin globals model

        PrivacyToggled (Err _) ->
            noCmd globals model

        ExpandSearchEditor ->
            expandSearchEditor globals model

        CollapseSearchEditor ->
            ( ( { model | searchEditor = FieldEditor.collapse model.searchEditor }
              , Cmd.none
              )
            , globals
            )

        SearchEditorChanged newValue ->
            ( ( { model | searchEditor = FieldEditor.setValue newValue model.searchEditor }
              , Cmd.none
              )
            , globals
            )

        SearchSubmitted ->
            let
                newSearchEditor =
                    model.searchEditor
                        |> FieldEditor.setIsSubmitting True

                searchParams =
                    Route.Search.init
                        (Route.Group.getSpaceSlug model.params)
                        (FieldEditor.getValue newSearchEditor)

                cmd =
                    Route.pushUrl globals.navKey (Route.Search searchParams)
            in
            ( ( { model | searchEditor = newSearchEditor }, cmd ), globals )

        CloseClicked ->
            let
                cmd =
                    globals.session
                        |> CloseGroup.request model.spaceId model.groupId
                        |> Task.attempt Closed
            in
            ( ( model, cmd ), globals )

        Closed (Ok ( newSession, CloseGroup.Success newGroup )) ->
            let
                newRepo =
                    globals.repo
                        |> Repo.setGroup newGroup
            in
            noCmd { globals | session = newSession, repo = newRepo } model

        Closed (Err Session.Expired) ->
            redirectToLogin globals model

        Closed (Err _) ->
            noCmd globals model

        ReopenClicked ->
            let
                cmd =
                    globals.session
                        |> ReopenGroup.request model.spaceId model.groupId
                        |> Task.attempt Reopened
            in
            ( ( model, cmd ), globals )

        Reopened (Ok ( newSession, ReopenGroup.Success newGroup )) ->
            let
                newRepo =
                    globals.repo
                        |> Repo.setGroup newGroup
            in
            noCmd { globals | session = newSession, repo = newRepo } model

        Reopened (Err Session.Expired) ->
            redirectToLogin globals model

        Reopened (Err _) ->
            noCmd globals model

        PostsDismissed _ ->
            noCmd { globals | flash = Flash.set Flash.Notice "Dismissed from inbox" 3000 globals.flash } model

        PostsMarkedAsRead _ ->
            noCmd { globals | flash = Flash.set Flash.Notice "Moved to inbox" 3000 globals.flash } model

        PostClosed _ ->
            noCmd { globals | flash = Flash.set Flash.Notice "Marked as resolved" 3000 globals.flash } model

        PostSelected postId ->
            let
                newPostComps =
                    Connection.selectBy .id postId model.postComps
            in
            ( ( { model | postComps = newPostComps }, Cmd.none ), globals )

        FocusOnComposer ->
            ( ( model, setFocus (PostEditor.getTextareaId model.postComposer) NoOp ), globals )

        PushSubscribeClicked ->
            ( ( model, ServiceWorker.pushSubscribe ), globals )

        NavToggled ->
            ( ( { model | showNav = not model.showNav }, Cmd.none ), globals )

        SidebarToggled ->
            ( ( { model | showSidebar = not model.showSidebar }, Cmd.none ), globals )

        ScrollTopClicked ->
            ( ( model, Scroll.toDocumentTop NoOp ), globals )


noCmd : Globals -> Model -> ( ( Model, Cmd Msg ), Globals )
noCmd globals model =
    ( ( model, Cmd.none ), globals )


redirectToLogin : Globals -> Model -> ( ( Model, Cmd Msg ), Globals )
redirectToLogin globals model =
    ( ( model, Route.toLogin ), globals )


expandSearchEditor : Globals -> Model -> ( ( Model, Cmd Msg ), Globals )
expandSearchEditor globals model =
    ( ( { model | searchEditor = FieldEditor.expand model.searchEditor }
      , setFocus (FieldEditor.getNodeId model.searchEditor) NoOp
      )
    , globals
    )


removePost : Globals -> Post -> ( Model, Cmd Msg ) -> ( Model, Cmd Msg )
removePost globals post ( model, cmd ) =
    case Connection.get .id (Post.id post) model.postComps of
        Just postComp ->
            let
                newPostComps =
                    Connection.remove .id (Post.id post) model.postComps

                teardownCmd =
                    Cmd.map (PostComponentMsg postComp.id)
                        (Component.Post.teardown globals postComp)

                newCmd =
                    Cmd.batch [ cmd, teardownCmd ]
            in
            ( { model | postComps = newPostComps }, newCmd )

        Nothing ->
            ( model, cmd )



-- EVENTS


consumeEvent : Globals -> Event -> Model -> ( Model, Cmd Msg )
consumeEvent globals event model =
    case event of
        Event.SubscribedToGroup group ->
            if Group.id group == model.groupId then
                ( model
                , FeaturedMemberships.request model.groupId globals.session
                    |> Task.attempt FeaturedMembershipsRefreshed
                )

            else
                ( model, Cmd.none )

        Event.UnsubscribedFromGroup group ->
            if Group.id group == model.groupId then
                ( model
                , FeaturedMemberships.request model.groupId globals.session
                    |> Task.attempt FeaturedMembershipsRefreshed
                )

            else
                ( model, Cmd.none )

        Event.PostCreated resolvedPost ->
            let
                ( postId, replyIds ) =
                    ResolvedPostWithReplies.unresolve resolvedPost

                postComp =
                    Component.Post.init
                        model.spaceId
                        postId
                        replyIds
            in
            if
                Route.Group.getState model.params
                    == Route.Group.Open
                    && List.member model.groupId (Post.groupIds resolvedPost.post)
            then
                ( { model | postComps = Connection.prepend .id postComp model.postComps }
                , Cmd.map (PostComponentMsg postId) (Component.Post.setup globals postComp)
                )

            else
                ( model, Cmd.none )

        Event.ReplyCreated reply ->
            let
                postId =
                    Reply.postId reply
            in
            case Connection.get .id postId model.postComps of
                Just postComp ->
                    let
                        ( newPostComp, cmd ) =
                            Component.Post.handleReplyCreated reply postComp
                    in
                    ( { model | postComps = Connection.update .id newPostComp model.postComps }
                    , Cmd.map (PostComponentMsg postId) cmd
                    )

                Nothing ->
                    ( model, Cmd.none )

        Event.PostDeleted post ->
            removePost globals post ( model, Cmd.none )

        _ ->
            ( model, Cmd.none )


consumeKeyboardEvent : Globals -> KeyboardShortcuts.Event -> Model -> ( ( Model, Cmd Msg ), Globals )
consumeKeyboardEvent globals event model =
    case ( event.key, event.modifiers ) of
        ( "/", [] ) ->
            expandSearchEditor globals model

        ( "k", [] ) ->
            let
                newPostComps =
                    Connection.selectPrev model.postComps

                cmd =
                    case Connection.selected newPostComps of
                        Just currentPost ->
                            Scroll.toAnchor Scroll.Document (Component.Post.postNodeId currentPost.postId) 85

                        Nothing ->
                            Cmd.none
            in
            ( ( { model | postComps = newPostComps }, cmd ), globals )

        ( "j", [] ) ->
            let
                newPostComps =
                    Connection.selectNext model.postComps

                cmd =
                    case Connection.selected newPostComps of
                        Just currentPost ->
                            Scroll.toAnchor Scroll.Document (Component.Post.postNodeId currentPost.postId) 85

                        Nothing ->
                            Cmd.none
            in
            ( ( { model | postComps = newPostComps }, cmd ), globals )

        ( "e", [] ) ->
            case Connection.selected model.postComps of
                Just currentPost ->
                    let
                        cmd =
                            globals.session
                                |> DismissPosts.request model.spaceId [ currentPost.postId ]
                                |> Task.attempt PostsDismissed
                    in
                    ( ( model, cmd ), globals )

                Nothing ->
                    ( ( model, Cmd.none ), globals )

        ( "e", [ Meta ] ) ->
            case Connection.selected model.postComps of
                Just currentPost ->
                    let
                        cmd =
                            globals.session
                                |> MarkAsRead.request model.spaceId [ currentPost.postId ]
                                |> Task.attempt PostsMarkedAsRead
                    in
                    ( ( model, cmd ), globals )

                Nothing ->
                    ( ( model, Cmd.none ), globals )

        ( "y", [] ) ->
            case Connection.selected model.postComps of
                Just currentPost ->
                    let
                        cmd =
                            globals.session
                                |> ClosePost.request model.spaceId currentPost.postId
                                |> Task.attempt PostClosed
                    in
                    ( ( model, cmd ), globals )

                Nothing ->
                    ( ( model, Cmd.none ), globals )

        ( "r", [] ) ->
            case Connection.selected model.postComps of
                Just currentPost ->
                    let
                        ( ( newCurrentPost, compCmd ), newGlobals ) =
                            Component.Post.expandReplyComposer globals currentPost

                        newPostComps =
                            Connection.update .id newCurrentPost model.postComps
                    in
                    ( ( { model | postComps = newPostComps }
                      , Cmd.map (PostComponentMsg currentPost.id) compCmd
                      )
                    , globals
                    )

                Nothing ->
                    ( ( model, Cmd.none ), globals )

        ( "c", [] ) ->
            ( ( model, setFocus (PostEditor.getTextareaId model.postComposer) NoOp ), globals )

        _ ->
            ( ( model, Cmd.none ), globals )



-- SUBSCRIPTION


subscriptions : Sub Msg
subscriptions =
    Sub.batch
        [ every 1000 Tick
        , PostEditor.receive PostEditorEventReceived
        ]



-- VIEW


view : Globals -> Model -> Html Msg
view globals model =
    case resolveData globals.repo model of
        Just data ->
            resolvedView globals model data

        Nothing ->
            text "Something went wrong."


resolvedView : Globals -> Model -> Data -> Html Msg
resolvedView globals model data =
    case globals.device of
        Device.Desktop ->
            resolvedDesktopView globals model data

        Device.Mobile ->
            resolvedMobileView globals model data



-- DESKTOP


resolvedDesktopView : Globals -> Model -> Data -> Html Msg
resolvedDesktopView globals model data =
    let
        config =
            { globals = globals
            , space = data.space
            , spaceUser = data.viewer
            , onNoOp = NoOp
            , onToggleKeyboardCommands = ToggleKeyboardCommands
            }
    in
    Layout.SpaceDesktop.layout config
        [ div [ class "mx-auto px-8 max-w-lg leading-normal" ]
            [ div [ class "scrolled-top-no-border sticky pin-t trans-border-b-grey py-3 bg-white z-40" ]
                [ div [ class "flex items-center" ]
                    [ nameView data.group model.nameEditor
                    , viewIf False <| bookmarkButtonView (Group.isBookmarked data.group)
                    , nameErrors model.nameEditor
                    , controlsView model
                    ]
                ]
            , viewIf (Group.state data.group == Group.Open) <|
                desktopPostComposerView globals model data
            , viewIf (Group.state data.group == Group.Closed) <|
                p [ class "flex items-center px-4 py-3 mb-4 bg-red-lightest border-b-2 border-red text-red font-bold" ]
                    [ div [ class "flex-grow" ] [ text "This channel is closed." ]
                    , div [ class "flex-no-shrink" ]
                        [ button [ class "btn btn-red btn-sm", onClick ReopenClicked ] [ text "Reopen the channel" ]
                        ]
                    ]
            , div [ class "sticky mb-4 pt-1 bg-white z-20", style "top" "56px" ]
                [ div [ class "mx-3 flex items-baseline trans-border-b-grey" ]
                    [ filterTab Device.Desktop "Open" Route.Group.Open (openParams model.params) model.params
                    , filterTab Device.Desktop "Resolved" Route.Group.Closed (closedParams model.params) model.params
                    ]
                ]
            , PushStatus.bannerView globals.pushStatus PushSubscribeClicked
            , desktopPostsView globals model data
            , viewUnless (Connection.isEmptyAndExpanded model.postComps) <|
                div [ class "mx-3 p-8 pb-16" ]
                    [ paginationView model.params model.postComps
                    ]
            , Layout.SpaceDesktop.rightSidebar (sidebarView data.space data.group data.featuredMembers model)
            ]
        ]


nameView : Group -> FieldEditor String -> Html Msg
nameView group editor =
    case ( FieldEditor.isExpanded editor, FieldEditor.isSubmitting editor ) of
        ( False, _ ) ->
            h2 [ class "flex-no-shrink" ]
                [ span [ class "text-2xl font-normal text-dusty-blue-dark" ] [ text "#" ]
                , span
                    [ onClick NameClicked
                    , class "font-bold text-2xl cursor-pointer"
                    ]
                    [ text (Group.name group) ]
                ]

        ( True, False ) ->
            h2 [ class "flex flex-no-shrink" ]
                [ div [ class "mr-1 text-2xl font-normal text-dusty-blue-dark" ] [ text "#" ]
                , input
                    [ type_ "text"
                    , id (FieldEditor.getNodeId editor)
                    , classList
                        [ ( "px-2 bg-grey-light font-bold text-2xl text-dusty-blue-darkest rounded no-outline js-stretchy", True )
                        , ( "shake", not <| List.isEmpty (FieldEditor.getErrors editor) )
                        ]
                    , value (FieldEditor.getValue editor)
                    , onInput NameEditorChanged
                    , onKeydown preventDefault
                        [ ( [], enter, \event -> NameEditorSubmit )
                        , ( [], esc, \event -> NameEditorDismissed )
                        ]
                    , onBlur NameEditorDismissed
                    ]
                    []
                ]

        ( _, True ) ->
            h2 [ class "flex-no-shrink" ]
                [ input
                    [ type_ "text"
                    , class "-ml-2 px-2 bg-grey-light font-bold text-2xl text-dusty-blue-darkest rounded no-outline"
                    , value (FieldEditor.getValue editor)
                    , disabled True
                    ]
                    []
                ]


privacyIcon : Bool -> Html Msg
privacyIcon isPrivate =
    if isPrivate == True then
        span [ class "mx-2" ] [ Icons.lock ]

    else
        span [ class "mx-2" ] [ Icons.unlock ]


nameErrors : FieldEditor String -> Html Msg
nameErrors editor =
    case ( FieldEditor.isExpanded editor, List.head (FieldEditor.getErrors editor) ) of
        ( True, Just error ) ->
            span [ class "ml-2 flex-grow text-sm text-red font-bold" ] [ text error.message ]

        ( _, _ ) ->
            text ""


controlsView : Model -> Html Msg
controlsView model =
    div [ class "flex flex-grow justify-end" ]
        [ searchEditorView model.searchEditor
        ]


searchEditorView : FieldEditor String -> Html Msg
searchEditorView editor =
    View.SearchBox.view
        { editor = editor
        , changeMsg = SearchEditorChanged
        , expandMsg = ExpandSearchEditor
        , collapseMsg = CollapseSearchEditor
        , submitMsg = SearchSubmitted
        }


desktopPostComposerView : Globals -> Model -> Data -> Html Msg
desktopPostComposerView globals model data =
    let
        editor =
            model.postComposer

        config =
            { editor = editor
            , spaceId = Space.id data.space
            , spaceUsers = Repo.getSpaceUsers (Space.spaceUserIds data.space) globals.repo
            , groups = Repo.getGroups (Space.groupIds data.space) globals.repo
            , onFileAdded = NewPostFileAdded
            , onFileUploadProgress = NewPostFileUploadProgress
            , onFileUploaded = NewPostFileUploaded
            , onFileUploadError = NewPostFileUploadError
            , classList = []
            }
    in
    PostEditor.wrapper config
        [ label [ class "composer" ]
            [ div [ class "flex" ]
                [ div [ class "flex-no-shrink mr-3" ] [ SpaceUser.avatar Avatar.Medium data.viewer ]
                , div [ class "flex-grow pt-2" ]
                    [ textarea
                        [ id (PostEditor.getTextareaId editor)
                        , class "w-full h-8 no-outline bg-transparent text-dusty-blue-darkest resize-none leading-normal"
                        , placeholder <| "Post in #" ++ Group.name data.group ++ "..."
                        , onInput NewPostBodyChanged
                        , onKeydown preventDefault [ ( [ Keys.Meta ], enter, \event -> NewPostSubmit ) ]
                        , readonly (PostEditor.isSubmitting editor)
                        , value (PostEditor.getBody editor)
                        ]
                        []
                    , PostEditor.filesView editor
                    , div [ class "flex items-center justify-end" ]
                        [ viewUnless (PostEditor.getIsUrgent editor) <|
                            button
                                [ class "tooltip tooltip-bottom mr-2 p-1 rounded-full bg-grey-light hover:bg-grey transition-bg no-outline"
                                , attribute "data-tooltip" "Interrupt all @mentioned people"
                                , onClick ToggleUrgent
                                ]
                                [ Icons.alert Icons.Off ]
                        , viewIf (PostEditor.getIsUrgent editor) <|
                            button
                                [ class "tooltip tooltip-bottom mr-2 p-1 rounded-full bg-grey-light hover:bg-grey transition-bg no-outline"
                                , attribute "data-tooltip" "Don't interrupt anyone"
                                , onClick ToggleUrgent
                                ]
                                [ Icons.alert Icons.On ]
                        , button
                            [ class "btn btn-blue btn-sm"
                            , onClick NewPostSubmit
                            , disabled (PostEditor.isUnsubmittable editor)
                            ]
                            [ text "Send" ]
                        ]
                    ]
                ]
            ]
        ]


desktopPostsView : Globals -> Model -> Data -> Html Msg
desktopPostsView globals model data =
    let
        spaceUsers =
            Repo.getSpaceUsers (Space.spaceUserIds data.space) globals.repo

        groups =
            Repo.getGroups (Space.groupIds data.space) globals.repo
    in
    if Connection.isEmptyAndExpanded model.postComps then
        div [ class "pt-16 pb-16 font-headline text-center text-lg text-dusty-blue-dark" ]
            [ text "You're all caught up!" ]

    else
        div [] <|
            Connection.mapList (desktopPostView globals spaceUsers groups model data) model.postComps


desktopPostView : Globals -> List SpaceUser -> List Group -> Model -> Data -> Component.Post.Model -> Html Msg
desktopPostView globals spaceUsers groups model data component =
    let
        config =
            { globals = globals
            , space = data.space
            , currentUser = data.viewer
            , now = model.now
            , spaceUsers = spaceUsers
            , groups = groups
            , showGroups = False
            }

        isSelected =
            Connection.selected model.postComps == Just component
    in
    div
        [ classList
            [ ( "relative mb-3 p-3", True )
            ]
        , onClick (PostSelected component.id)
        ]
        [ viewIf isSelected <|
            div
                [ class "tooltip tooltip-top cursor-default absolute mt-4 w-2 h-2 rounded-full pin-t pin-l bg-green"
                , attribute "data-tooltip" "Currently selected"
                ]
                []
        , component
            |> Component.Post.view config
            |> Html.map (PostComponentMsg component.id)
        ]



-- MOBILE


resolvedMobileView : Globals -> Model -> Data -> Html Msg
resolvedMobileView globals model data =
    let
        config =
            { globals = globals
            , space = data.space
            , spaceUser = data.viewer
            , title = "#" ++ Group.name data.group
            , showNav = model.showNav
            , onNavToggled = NavToggled
            , onSidebarToggled = SidebarToggled
            , onScrollTopClicked = ScrollTopClicked
            , onNoOp = NoOp
            , leftControl = Layout.SpaceMobile.ShowNav
            , rightControl = Layout.SpaceMobile.ShowSidebar
            }
    in
    Layout.SpaceMobile.layout config
        [ div [ class "flex justify-center items-baseline mb-3 px-3 pt-2 border-b" ]
            [ filterTab Device.Mobile "Open" Route.Group.Open (openParams model.params) model.params
            , filterTab Device.Mobile "Resolved" Route.Group.Closed (closedParams model.params) model.params
            ]
        , viewIf (Group.state data.group == Group.Closed) <|
            p [ class "flex items-center px-4 py-3 mb-4 bg-red-lightest border-b-2 border-red text-red font-bold" ]
                [ div [ class "flex-grow" ] [ text "This group is closed." ]
                , div [ class "flex-no-shrink" ]
                    [ button [ class "btn btn-blue btn-sm", onClick ReopenClicked ] [ text "Reopen this group" ]
                    ]
                ]
        , PushStatus.bannerView globals.pushStatus PushSubscribeClicked
        , div [ class "p-3 pt-0" ]
            [ mobilePostsView globals model data
            , viewUnless (Connection.isEmptyAndExpanded model.postComps) <|
                div [ class "mx-3 p-8 pb-16 border-t" ]
                    [ paginationView model.params model.postComps
                    ]
            ]
        , a
            [ Route.href <| Route.NewGroupPost (Route.NewGroupPost.init (Route.Group.getSpaceSlug model.params) (Route.Group.getGroupName model.params))
            , class "flex items-center justify-center fixed w-16 h-16 bg-turquoise rounded-full shadow"
            , style "bottom" "25px"
            , style "right" "25px"
            ]
            [ Icons.commentWhite ]
        , viewIf model.showSidebar <|
            Layout.SpaceMobile.rightSidebar config
                [ div [ class "p-6" ] (sidebarView data.space data.group data.featuredMembers model)
                ]
        ]


mobilePostsView : Globals -> Model -> Data -> Html Msg
mobilePostsView globals model data =
    let
        spaceUsers =
            Repo.getSpaceUsers (Space.spaceUserIds data.space) globals.repo

        groups =
            Repo.getGroups (Space.groupIds data.space) globals.repo
    in
    if Connection.isEmptyAndExpanded model.postComps then
        div [ class "pt-16 pb-16 font-headline text-center text-lg" ]
            [ text "You’re all caught up!" ]

    else
        div [] <|
            Connection.mapList (mobilePostView globals spaceUsers groups model data) model.postComps


mobilePostView : Globals -> List SpaceUser -> List Group -> Model -> Data -> Component.Post.Model -> Html Msg
mobilePostView globals spaceUsers groups model data component =
    let
        config =
            { globals = globals
            , space = data.space
            , currentUser = data.viewer
            , now = model.now
            , spaceUsers = spaceUsers
            , groups = groups
            , showGroups = False
            }
    in
    div [ class "py-4" ]
        [ component
            |> Component.Post.view config
            |> Html.map (PostComponentMsg component.id)
        ]



-- SHARED


filterTab : Device -> String -> Route.Group.State -> Params -> Params -> Html Msg
filterTab device label state linkParams currentParams =
    let
        isCurrent =
            Route.Group.getState currentParams == state
    in
    a
        [ Route.href (Route.Group linkParams)
        , classList
            [ ( "flex-1 block text-md py-3 px-4 border-b-3 border-transparent no-underline font-bold text-center", True )
            , ( "text-dusty-blue", not isCurrent )
            , ( "border-turquoise text-turquoise-dark", isCurrent )
            ]
        ]
        [ text label ]


paginationView : Params -> Connection a -> Html Msg
paginationView params connection =
    Pagination.view connection
        (\beforeCursor -> Route.Group (Route.Group.setCursors (Just beforeCursor) Nothing params))
        (\afterCursor -> Route.Group (Route.Group.setCursors Nothing (Just afterCursor) params))


bookmarkButtonView : Bool -> Html Msg
bookmarkButtonView isBookmarked =
    if isBookmarked == True then
        button
            [ class "ml-3 tooltip tooltip-bottom"
            , onClick Unbookmark
            , attribute "data-tooltip" "Unbookmark"
            ]
            [ Icons.bookmark Icons.On ]

    else
        button
            [ class "ml-3 tooltip tooltip-bottom"
            , onClick Bookmark
            , attribute "data-tooltip" "Bookmark"
            ]
            [ Icons.bookmark Icons.Off ]


sidebarView : Space -> Group -> List SpaceUser -> Model -> List (Html Msg)
sidebarView space group featuredMembers model =
    let
        settingsParams =
            Route.GroupSettings.init
                (Route.Group.getSpaceSlug model.params)
                (Route.Group.getGroupName model.params)
                Route.GroupSettings.General
    in
    [ h3 [ class "flex items-baseline mb-2 text-base font-bold" ]
        [ span [ class "mr-2" ] [ text "Subscribers" ]
        , viewIf (Group.isPrivate group) <|
            div [ class "tooltip tooltip-bottom font-sans", attribute "data-tooltip" "This channel is private" ] [ Icons.lock ]
        ]
    , memberListView space featuredMembers
    , ul [ class "list-reset leading-normal" ]
        [ viewUnless (Group.membershipState group == GroupMembership.NotSubscribed) <|
            li [ class "flex mb-3" ]
                [ label
                    [ class "control checkbox tooltip tooltip-bottom tooltip-wide"
                    , attribute "data-tooltip" "By default, only posts where you are @mentioned go to your Inbox"
                    ]
                    [ input
                        [ type_ "checkbox"
                        , class "checkbox"
                        , onClick ToggleWatching
                        , checked model.isWatching
                        ]
                        []
                    , span [ class "control-indicator w-4 h-4 mr-2 border" ] []
                    , span [ class "select-none text-md text-dusty-blue-dark" ] [ text "Send all to Inbox" ]
                    ]
                ]
        , li []
            [ subscribeButtonView (Group.membershipState group)
            ]
        , li []
            [ a
                [ Route.href (Route.GroupSettings settingsParams)
                , class "text-md text-dusty-blue no-underline font-bold"
                ]
                [ text "Settings" ]
            ]
        ]
    ]


memberListView : Space -> List SpaceUser -> Html Msg
memberListView space featuredMembers =
    if List.isEmpty featuredMembers then
        div [ class "pb-4 text-md text-dusty-blue-darker" ] [ text "Nobody is subscribed." ]

    else
        div [ class "pb-4" ] <| List.map (memberItemView space) featuredMembers


memberItemView : Space -> SpaceUser -> Html Msg
memberItemView space user =
    a
        [ Route.href <| Route.SpaceUser (Route.SpaceUser.init (Space.slug space) (SpaceUser.handle user))
        , class "flex items-center pr-4 mb-px no-underline text-dusty-blue-darker"
        ]
        [ div [ class "flex-no-shrink mr-2" ] [ SpaceUser.avatar Avatar.Tiny user ]
        , div [ class "flex-grow text-md truncate" ] [ text <| SpaceUser.displayName user ]
        ]


subscribeButtonView : GroupMembershipState -> Html Msg
subscribeButtonView state =
    case state of
        GroupMembership.NotSubscribed ->
            button
                [ class "text-md text-dusty-blue no-underline font-bold"
                , onClick SubscribeClicked
                ]
                [ text "Subscribe" ]

        GroupMembership.Subscribed ->
            button
                [ class "text-md text-dusty-blue no-underline font-bold"
                , onClick UnsubscribeClicked
                ]
                [ text "Unsubscribe" ]

        GroupMembership.Watching ->
            button
                [ class "text-md text-dusty-blue no-underline font-bold"
                , onClick UnsubscribeClicked
                ]
                [ text "Unsubscribe" ]



-- INTERNAL


openParams : Params -> Params
openParams params =
    params
        |> Route.Group.setCursors Nothing Nothing
        |> Route.Group.setState Route.Group.Open


closedParams : Params -> Params
closedParams params =
    params
        |> Route.Group.setCursors Nothing Nothing
        |> Route.Group.setState Route.Group.Closed

!
!////////////////////////////////////////////////////////////////////////
!
!      HexMesh.f95
!      Created: 2007-03-22 17:05:00 -0400 
!      By: David Kopriva  
!
!
!////////////////////////////////////////////////////////////////////////
!
#include "Includes.h"
MODULE HexMeshClass
      USE MeshTypes
      USE NodeClass
      USE ElementClass
      USE FaceClass
      USE TransfiniteMapClass
      use SharedBCModule
      use ElementConnectivityDefinitions
      use ZoneClass
      use PhysicsStorage
      IMPLICIT NONE
!
!     ---------------
!     Mesh definition
!     ---------------
!
      type HexMesh
         integer                                   :: numberOfFaces
         integer                                   :: no_of_elements
         integer      , dimension(:), allocatable  :: Ns              !Polynomial orders of all elements
         type(Node)   , dimension(:), allocatable  :: nodes
         type(Face)   , dimension(:), allocatable  :: faces
         type(Element), dimension(:), allocatable  :: elements
         class(Zone_t), dimension(:), allocatable  :: zones
         contains
            procedure :: constructFromFile => ConstructMesh_FromFile_
            procedure :: destruct          => DestructMesh
            procedure :: Describe          => DescribeMesh
            procedure :: ConstructZones    => HexMesh_ConstructZones
            procedure :: SetConnectivities => HexMesh_SetConnectivities
            procedure :: Export            => HexMesh_Export
            procedure :: SaveSolution      => HexMesh_SaveSolution
            procedure :: SaveStatistics    => HexMesh_SaveStatistics
            procedure :: ResetStatistics   => HexMesh_ResetStatistics
            procedure :: LoadSolution      => HexMesh_LoadSolution
            procedure :: WriteCoordFile
      end type HexMesh

      TYPE Neighbour         ! added to introduce colored computation of numerical Jacobian (is this the best place to define this type??) - only usable for conforming meshes
         INTEGER :: elmnt(7) ! "7" hardcoded for 3D hexahedrals in conforming meshes... This definition must change if the code is expected to be more general
      END TYPE Neighbour

!
!     ========
      CONTAINS
!     ========
!
!
!////////////////////////////////////////////////////////////////////////
!
!!    Constructs mesh from mesh file
!!    Only valid for conforming meshes
      SUBROUTINE ConstructMesh_FromFile_( self, fileName, spA, Nx, Ny, Nz, success )
         USE Physics
         IMPLICIT NONE
!
!        ---------------
!        Input variables
!        ---------------
!
         CLASS(HexMesh)     :: self
         TYPE(NodalStorage) :: spA(0:,0:,0:)
         CHARACTER(LEN=*)   :: fileName
         INTEGER            :: Nx(:), Ny(:), Nz(:)     !<  Polynomial orders for all the elements
         LOGICAL            :: success
!
!        ---------------
!        Local variables
!        ---------------
!
         TYPE(TransfiniteHexMap), POINTER :: hexMap, hex8Map, genHexMap
         
         INTEGER                         :: numberOfElements
         INTEGER                         :: numberOfNodes
         INTEGER                         :: numberOfBoundaryFaces
         INTEGER                         :: numberOfFaces
         
         INTEGER                         :: bFaceOrder, numBFacePoints
         INTEGER                         :: i, j, k, l
         INTEGER                         :: fUnit, fileStat
         INTEGER                         :: nodeIDs(NODES_PER_ELEMENT), nodeMap(NODES_PER_FACE)
         REAL(KIND=RP)                   :: x(NDIM)
         INTEGER                         :: faceFlags(FACES_PER_ELEMENT)
         CHARACTER(LEN=BC_STRING_LENGTH) :: names(FACES_PER_ELEMENT)
         TYPE(FacePatch), DIMENSION(6)   :: facePatches
         REAL(KIND=RP)                   :: corners(NDIM,NODES_PER_ELEMENT)
         INTEGER, EXTERNAL               :: UnusedUnit
!
!        ------------------
!        For curved patches
!        ------------------
!
         REAL(KIND=RP)  , DIMENSION(:)    , ALLOCATABLE :: uNodes, vNodes
         REAL(KIND=RP)  , DIMENSION(:,:,:), ALLOCATABLE :: values
!
!        ----------------
!        For flat patches
!        ----------------
!
         REAL(KIND=RP)  , DIMENSION(2)     :: uNodesFlat = [-1.0_RP,1.0_RP]
         REAL(KIND=RP)  , DIMENSION(2)     :: vNodesFlat = [-1.0_RP,1.0_RP]
         REAL(KIND=RP)  , DIMENSION(3,2,2) :: valuesFlat
          
         numberOfBoundaryFaces = 0
         corners               = 0.0_RP
         success               = .TRUE.
         
         ALLOCATE(hex8Map)
         CALL hex8Map % constructWithCorners(corners)
         ALLOCATE(genHexMap)
!
!        -----------------------
!        Read header information
!        -----------------------
!
         fUnit = UnusedUnit()
         OPEN( UNIT = fUnit, FILE = fileName, iostat = fileStat )
         IF ( fileStat /= 0 )     THEN
            PRINT *, "Error opening file: ", fileName
            success = .FALSE.
            RETURN 
         END IF
         
         READ(fUnit,*) numberOfNodes, numberOfElements, bFaceOrder

         self % no_of_elements = numberOfElements
!
!        ---------------
!        Allocate memory
!        ---------------
!
         ALLOCATE( self % elements(numberOfelements) )
         ALLOCATE( self % nodes(numberOfNodes) )
!
!        ----------------------------
!        Set up for face patches
!        Face patches are defined 
!        at chebyshev- lobatto points
!        ----------------------------
!
         numBFacePoints = bFaceOrder + 1
         ALLOCATE(uNodes(numBFacePoints))
         ALLOCATE(vNodes(numBFacePoints))
         ALLOCATE(values(3,numBFacePoints,numBFacePoints))
         
         DO i = 1, numBFacePoints
            uNodes(i) = -COS((i-1)*PI/(numBFacePoints-1)) 
            vNodes(i) = -COS((i-1)*PI/(numBFacePoints-1)) 
         END DO
         
         DO k = 1, 6 ! Most patches will be flat, so set up for self
            CALL facePatches(k) % construct(uNodesFlat,vNodesFlat) 
         END DO  
!
!        ----------------------------------
!        Read nodes: Nodes have the format:
!        x y z
!        ----------------------------------
!
         DO j = 1, numberOfNodes 
            READ( fUnit, * ) x
            CALL ConstructNode( self % nodes(j), x )
         END DO
!
!        -----------------------------------------
!        Read elements: Elements have the format:
!        node1ID node2ID node3ID node4ID ... node8ID
!        b1 b2 b3 b4 b5 b6
!           (=0 for straight side, 1 for curved)
!        If curved boundaries, then for each:
!           for j = 0 to bFaceOrder
!              x_j  y_j  z_j
!           next j
!        bname1 bname2 bname3 bname4 bname5 bname6
!        -----------------------------------------
!
         DO l = 1, numberOfElements 
            READ( fUnit, * ) nodeIDs
            READ( fUnit, * ) faceFlags
!
!           -----------------------------------------------------------------------------
!           If the faceFlags are all zero, then self is a straight-sided
!           hex. In that case, set the corners of the hex8Map and use that in determining
!           the element geometry.
!           -----------------------------------------------------------------------------
!
            IF(MAXVAL(faceFlags) == 0)     THEN
               DO k = 1, NODES_PER_ELEMENT
                  corners(:,k) = self % nodes(nodeIDs(k)) % x
               END DO
               CALL hex8Map % setCorners(corners)
               hexMap => hex8Map
            ELSE
!
!              --------------------------------------------------------------
!              Otherwise, we have to look at each of the faces of the element 
!              --------------------------------------------------------------
!
               DO k = 1, FACES_PER_ELEMENT 
                 IF ( faceFlags(k) == 0 )     THEN
!
!                    ----------
!                    Flat faces
!                    ----------
!
                     nodeMap           = localFaceNode(:,k)
                     valuesFlat(:,1,1) = self % nodes(nodeIDs(nodeMap(1))) % x
                     valuesFlat(:,2,1) = self % nodes(nodeIDs(nodeMap(2))) % x
                     valuesFlat(:,2,2) = self % nodes(nodeIDs(nodeMap(3))) % x
                     valuesFlat(:,1,2) = self % nodes(nodeIDs(nodeMap(4))) % x
                     
                     IF(facePatches(k) % noOfKnots(1) /= 2)     THEN
                        CALL facePatches(k) % destruct()
                        CALL facePatches(k) % construct(uNodesFlat, vNodesFlat, valuesFlat)
                     ELSE
                        CALL facePatches(k) % setFacePoints(points = valuesFlat)
                     END IF 
                     
                  ELSE
!
!                    -------------
!                    Curved faces 
!                    -------------
!
                     DO j = 1, numBFacePoints
                        DO i = 1, numBFacePoints
                           READ( fUnit, * ) values(:,i,j)
                        END DO  
                     END DO
                        
                     IF(facePatches(k) % noOfKnots(1) == 2)     THEN             ! TODO This could be problematic with anisotropy
                        CALL facePatches(k) % destruct()
                        CALL facePatches(k) % construct(uNodes, vNodes, values)
                     ELSE
                       CALL facePatches(k) % setFacePoints(points = values)
                     END IF 
                     
                  END IF
               END DO
               CALL genHexMap % destruct()
               CALL genHexMap % constructWithFaces(facePatches)
               
               hexMap => genHexMap
            END IF 
!
!           -------------------------
!           Now construct the element
!           -------------------------
!
            CALL ConstructElementGeometry( self % elements(l), spA(Nx(l),Ny(l),Nz(l)), nodeIDs, hexMap )
            
            READ( fUnit, * ) names
            CALL SetElementBoundaryNames( self % elements(l), names )
            
            DO k = 1, 6
               IF(TRIM(names(k)) /= emptyBCName) numberOfBoundaryFaces = numberOfBoundaryFaces + 1
            END DO  
            
!
!           ------------------------------------
!           Construct the element connectivities
!           ------------------------------------
!
            DO k = 1, 6
               IF (TRIM(names(k)) == emptyBCName ) THEN
                  self%elements(l)%NumberOfConnections(k) = 1
                  CALL self%elements(l)%Connection(k)%construct (1)  ! Just conforming elements
               ELSE
                  self%elements(l)%NumberOfConnections(k) = 0
               ENDIF
            ENDDO
            
            
         END DO      ! l = 1, numberOfElement
        
!
!        ---------------------------
!        Construct the element faces
!        ---------------------------
!
         numberOfFaces        = (6*numberOfElements + numberOfBoundaryFaces)/2
         self % numberOfFaces = numberOfFaces
         ALLOCATE( self % faces(self % numberOfFaces) )
         CALL ConstructFaces( self, success )
!
!        ------------------------------
!        Set the element connectivities
!        ------------------------------
!
         call self % SetConnectivities
!
!        -------------------------
!        Build the different zones
!        -------------------------
!
         call self % ConstructZones()
!
!        ---------------------------
!        Construct periodic faces
!        ---------------------------
!
         CALL ConstructPeriodicFaces( self )
!
!        ---------------------------
!        Delete periodic- faces
!        ---------------------------
!
         CALL DeletePeriodicMinusFaces( self )

            
         CLOSE( fUnit )
!
!        ---------
!        Finish up
!        ---------
!
         CALL hex8Map % destruct()
         DEALLOCATE(hex8Map)
         CALL genHexMap % destruct()
         DEALLOCATE(genHexMap)

         CALL self % Describe( trim(fileName) )
         
         self % Ns = Nx

         call self % Export( trim(fileName) )
         
      END SUBROUTINE ConstructMesh_FromFile_

!
!     -----------
!     Destructors
!     -----------
!
!////////////////////////////////////////////////////////////////////////
!
      SUBROUTINE DestructMesh( self )
         IMPLICIT NONE 
         CLASS(HexMesh) :: self
         INTEGER        :: j
!
!        -----
!        Nodes
!        -----
!
         DO j = 1, SIZE( self % nodes )
            CALL DestructNode( self % nodes(j)) 
         END DO  
         DEALLOCATE( self % nodes )
!
!        --------
!        Elements
!        --------
!
         DO j = 1, SIZE(self % elements) 
            CALL DestructElement( self % elements(j) )
         END DO
         DEALLOCATE( self % elements )
!
!        -----
!        Faces
!        -----
!
         DO j = 1, SIZE(self % faces) 
            CALL DestructFace( self % faces(j) )
         END DO
         DEALLOCATE( self % faces )
!
!        -----
!        Zones
!        -----
!
         if (allocated(self % zones)) DEALLOCATE( self % zones )

         
      END SUBROUTINE DestructMesh
!
!     -------------
!     Print methods
!     -------------
!
!////////////////////////////////////////////////////////////////////////
!
      SUBROUTINE PrintMesh( self ) 
      IMPLICIT NONE 
      TYPE(HexMesh) :: self
      INTEGER ::  k
      
      PRINT *, "Nodes..."
      DO k = 1, SIZE(self % nodes)
         CALL PrintNode( self % nodes(k), k )
      END DO
      PRINT *, "Elements..."
      DO k = 1, SIZE(self % elements) 
         CALL PrintElement( self % elements(k), k )
      END DO
      PRINT *, "Faces..."
      DO k = 1, SIZE(self % faces) 
         CALL PrintFace( self % faces(k))
      END DO
      
      END SUBROUTINE PrintMesh
!
!//////////////////////////////////////////////////////////////////////// 
! 
      SUBROUTINE ConstructFaces( self, success )
!
!     -------------------------------------------------------------
!     Go through the elements and find the unique faces in the mesh
!     -------------------------------------------------------------
!
         USE FTMultiIndexTableClass 
         USE FTValueClass
         
         IMPLICIT NONE  
         TYPE(HexMesh) :: self
         LOGICAL       :: success
         
         INTEGER                 :: eID, faceNumber
         INTEGER                 :: faceID
         INTEGER                 :: nodeIDs(8), faceNodeIDs(4), j
         
         CLASS(FTMultiIndexTable), POINTER  :: table
         CLASS(FTObject), POINTER :: obj
         CLASS(FTValue) , POINTER :: v
         
         ALLOCATE(table)
         CALL table % initWithSize( SIZE( self % nodes) )
         
         self % numberOfFaces = 0
         DO eID = 1, SIZE( self % elements )
         
            nodeIDs = self % elements(eID) % nodeIDs
            DO faceNumber = 1, 6
               DO j = 1, 4
                  faceNodeIDs(j) = nodeIDs(localFaceNode(j,faceNumber)) 
               END DO
            
               IF ( table % containsKeys(faceNodeIDs) )     THEN
!
!                 --------------------------------------------------------------
!                 Add this element to the slave side of the face associated with
!                 these nodes.
!                 --------------------------------------------------------------
!
                  obj => table % objectForKeys(faceNodeIDs)
                  v   => valueFromObject(obj)
                  faceID = v % integerValue()
                  
                  self % faces(faceID) % elementIDs(2)  = eID
                  self % faces(faceID) % elementSide(2) = faceNumber
                  self % faces(faceID) % FaceType       = HMESH_INTERIOR
                  self % faces(faceID) % rotation       = faceRotation(masterNodeIDs = self % faces(faceID) % nodeIDs       , &
                                                                       slaveNodeIDs  = faceNodeIDs                          , &
                                                                       masterSide    = self % faces(faceID) % elementSide(1), &
                                                                       slaveSide     = faceNumber)
               ELSE 
!
!                 ------------------
!                 Construct new face
!                 ------------------
!
                  self % numberOfFaces = self % numberOfFaces + 1
                  
                  IF(self % numberOfFaces > SIZE(self % faces))     THEN
          
                     CALL release(table)
                     PRINT *, "Too many faces for # of elements:", self % numberOfFaces, " vs ", SIZE(self % faces)
                     success = .FALSE.
                     RETURN  
                  END IF 
                  
                  CALL ConstructFace( self % faces(self % numberOfFaces),   &
                                       nodeIDs = faceNodeIDs, &
                                       elementID = eID,       &
                                       side = faceNumber)
                  self % faces(self % numberOfFaces) % boundaryName = &
                           self % elements(eID) % boundaryName(faceNumber)
!
!                 ----------------------------------------------
!                 Mark which face is associated with these nodes
!                 ----------------------------------------------
!
                  ALLOCATE(v)
                  CALL v % initWithValue(self % numberOfFaces)
                  obj => v
                  CALL table % addObjectForKeys(obj,faceNodeIDs)
                  CALL release(v)
               END IF 
            END DO 
              
         END DO  
         
         CALL release(table)
         
      END SUBROUTINE ConstructFaces
!
!//////////////////////////////////////////////////////////////////////// 
! 
!
!---------------------------------------------------------------------
!! Element faces can be rotated with respect to each other. Orientation
!! gives the relative orientation of the master (1) face to the 
!! slave (2) face . In this routine,
!! orientation is measured in 90 degree increments:
!!                   rotation angle = orientation*pi/2
!!
!! As an example, faceRotation = 1 <=> rotating master by 90 deg. 
!
      INTEGER FUNCTION faceRotation( masterNodeIDs, slaveNodeIDs,masterSide   , slaveSide)
         IMPLICIT NONE 
         INTEGER               :: masterSide   , slaveSide    !< Sides connected in interface
         INTEGER, DIMENSION(4) :: masterNodeIDs, slaveNodeIDs !< Node IDs
         !-----------------------------------------------------
         INTEGER, DIMENSION(3), PARAMETER :: CCW = (/1, 5, 4/) ! Faces that are numbered counter-clockwise
         INTEGER, DIMENSION(3), PARAMETER :: CW  = (/2, 3, 6/) ! Faces that are numbered clockwise
         
         INTEGER :: j
         !-----------------------------------------------------
         
         DO j = 1, 4
            IF(masterNodeIDs(1) == slaveNodeIDs(j)) EXIT 
         END DO  
         
         IF ((ANY(CCW == masterSide) .AND. ANY(CW  == slaveSide)) .OR. &
             (ANY(CW  == masterSide) .AND. ANY(CCW == slaveSide))      ) THEN
            faceRotation = j - 1
         ELSE
            faceRotation = j + 3
         END IF
      END FUNCTION faceRotation
! 
!//////////////////////////////////////////////////////////////////////// 
!
      SUBROUTINE ConstructPeriodicFaces(self) 
      USE Physics
      IMPLICIT NONE  
! 
!------------------------------------------------------------------- 
! This subroutine looks for periodic boundary conditions. If they 
! are found, periodic+ face is set as an interior face. The slave 
! face is the periodic- face and will be deleted in the following
! step. 
!------------------------------------------------------------------- 
! 
! 
!-------------------- 
! External variables 
!-------------------- 
!  
      TYPE(HexMesh) :: self

! 
!-------------------- 
! Local variables 
!-------------------- 
! 
!
      REAL(KIND=RP) :: x1(NDIM), x2(NDIM)
      LOGICAL       :: master_matched(4), slave_matched(4)
      INTEGER       :: coord
      
      INTEGER       :: i,j,k,l 
      integer       :: zIDplus, zIDMinus, iFace, jFace
!
!     ---------------------------------------------
!     Loop to find faces with the label "periodic+"
!     ---------------------------------------------
!
!     ------------------------------
!     Loop zones with BC "periodic+"
!     ------------------------------
!
      if ( bcTypeDictionary % COUNT() .eq. 0 ) return
      do zIDPlus = 1, size(self % zones)
!
!        Cycle if the zone is not periodic+
!        ----------------------------------
         if ( trim(bcTypeDictionary % stringValueForKey(key = self % zones(zIDPlus) % Name, &
                                                      requestedLength = BC_STRING_LENGTH)) .ne. "periodic+") cycle
!
!        ------------------------------
!        Loop zones with BC "periodic-"
!        ------------------------------
!
         do zIDMinus = 1, size(self % zones)
!
!           Cycle if the zone is not periodic-
!           ----------------------------------
            if ( trim(bcTypeDictionary % stringValueForKey(key = self % zones(zIDMinus) % Name, &
                                                      requestedLength = BC_STRING_LENGTH)) .ne. "periodic-") cycle
!
!           Loop all faces in both zones
!           ----------------------------
            do iFace = 1, self % zones(zIDPlus) % no_of_faces;    do jFace = 1, self % zones(zIDMinus) % no_of_faces
               i = self % zones(zIDPlus) % faces(iFace)
               j = self % zones(zIDMinus) % faces(jFace)
!
!              ----------------------------------------------------------------------------------------
!              The index i is a periodic+ face
!              The index j is a periodic- face
!              We are looking for couples of periodic+ and periodic- faces where 2 of the 3 coordinates
!              in all the corners are shared. The non-shared coordinate has to be always the same one.
!              ----------------------------------------------------------------------------------------
!
               coord = 0                         ! This is the non-shared coordinate
               master_matched(:)   = .FALSE.     ! True if the master corner finds a partner
               slave_matched(:)    = .FALSE.     ! True if the slave corner finds a partner
               
               DO k = 1, 4
                  x1 = self%nodes(self%faces(i)%nodeIDs(k))%x                           !x1 is the master coordinate
                  DO l = 1, 4
                     IF (.NOT.slave_matched(l)) THEN 
                        x2 = self%nodes(self%faces(j)%nodeIDs(l))%x                     !x2 is the slave coordinate
                        CALL CompareTwoNodes(x1, x2, master_matched(k), coord)          !x1 and x2 are compared here
                        IF (master_matched(k)) THEN 
                           slave_matched(l) = .TRUE. 
                           EXIT
                        ENDIF  
                     ENDIF 
                  ENDDO 
                  IF (.NOT.master_matched(k)) EXIT  
               ENDDO          
               
               IF ( (master_matched(1)) .AND. (master_matched(2)) .AND. (master_matched(3)) .AND. (master_matched(4)) ) THEN
                  self % faces(i) % boundaryName   = ""
                  self % faces(i) % elementIDs(2)  = self % faces(j) % elementIDs(1)
                  self % faces(i) % elementSide(2) = self % faces(j) % elementSide(1) 
                  self % faces(i) % FaceType       = HMESH_INTERIOR
                  self % faces(i) % rotation       = 0!faceRotation(masterNodeIDs = self % faces(i) % nodeIDs, &
                                                     !           slaveNodeIDs  = self % faces(i) % nodeIDs)      
                                                                            
               ENDIF    
            end do;  end do
         end do
      end do
           
      END SUBROUTINE ConstructPeriodicFaces
! 
!//////////////////////////////////////////////////////////////////////// 
!     
      SUBROUTINE CompareTwoNodes(x1, x2, success, coord) 
      IMPLICIT NONE  
! 
!------------------------------------------------------------------- 
! Comparison of two nodes. If two of the three coordinates are the 
! same, there is success. If there is success, the coordinate which 
! is not the same is saved. If the initial value of coord is not 0, 
! only that coordinate is checked. 
!------------------------------------------------------------------- 
! 
! 
!     -------------------- 
!     External variables 
!     -------------------- 
!  
      REAL(KIND=RP) :: x1(3)
      REAL(KIND=RP) :: x2(3)
      LOGICAL       :: success
      INTEGER       :: coord 
!
!     ---------
!     Externals
!     ---------
!
      LOGICAL, EXTERNAL :: AlmostEqual
! 
!     -------------------- 
!     Local variables 
!     -------------------- 
! 
      INTEGER :: i
      INTEGER :: counter    
      
      counter = 0
      
      IF (coord == 0) THEN

         DO i = 1,3
            IF ( AlmostEqual( x1(i), x2(i) ) ) THEN 
               counter = counter + 1
            ELSE 
               coord = i
            ENDIF  
         ENDDO 
         
         IF (counter.ge.2) THEN 
            success = .TRUE.
         ELSE 
            success = .FALSE. 
         ENDIF  
         
      ELSE 

         DO i = 1,3
            IF (i /= coord) THEN 
               IF ( AlmostEqual( x1(i), x2(i) ) ) THEN 
                  counter = counter + 1
               ENDIF 
            ENDIF 
         ENDDO 
         
         IF (counter.ge.2) THEN 
            success = .TRUE.
         ELSE           
            success = .FALSE. 
         ENDIF  
   
      ENDIF
          
             
      END SUBROUTINE CompareTwoNodes
! 
!//////////////////////////////////////////////////////////////////////// 
!
      SUBROUTINE DeletePeriodicminusfaces(self) 
      IMPLICIT NONE  
! 
!------------------------------------------------------------------- 
! This subroutine looks for periodic boundary conditions. If they 
! are found, periodic+ face is set as an interior face. The slave 
! face is the periodic- face and will be deleted in the following
! step. 
!------------------------------------------------------------------- 
! 
! 
!     -------------------- 
!     External variables 
!     -------------------- 
!  
      TYPE(HexMesh) :: self
! 
!     -------------------- 
!     Local variables 
!     -------------------- 
! 
      TYPE(Face),ALLOCATABLE  :: dummy_faces(:)
      INTEGER                 :: i
      INTEGER                 :: iFace, numberOfFaces
      
         
      iFace = 0
      ALLOCATE( dummy_faces(self % numberOfFaces) )
      DO i = 1, self%numberOfFaces 
         IF (TRIM(bcTypeDictionary % stringValueForKey(key             = self%faces(i)%boundaryName, &
                                                      requestedLength = BC_STRING_LENGTH)) /= "periodic-") THEN 
            iFace = iFace + 1
            dummy_faces(iFace) = self%faces(i)
         ENDIF 
      ENDDO
       
      numberOfFaces = iFace

      IF (numberOfFaces /= self%numberOfFaces) THEN     
         PRINT*, "WARNING: FACE ROTATION IN PERIODIC BOUNDARY CONDITIONS NOT IMPLEMENTED YET"
         PRINT*, "IF A PROBLEM IS SUSPECTED, CONTACT THE DEVELOPERS WITH YOUR MESH FILE"
      ENDIF            

      DEALLOCATE(self%faces)
      ALLOCATE(self%faces(numberOfFaces))
      
      self%numberOfFaces = numberOfFaces
      
      DO i = 1, self%numberOfFaces
         self%faces(i) = dummy_faces(i)
      ENDDO 
      
           
      END SUBROUTINE DeletePeriodicminusfaces
! 
!//////////////////////////////////////////////////////////////////////// 
! 
      SUBROUTINE DescribeMesh( self , fileName )
      USE Headers
      IMPLICIT NONE
!
!--------------------------------------------------------------------
!  This subroutine describes the loaded mesh
!--------------------------------------------------------------------
!
!
!     ------------------
!     External variables
!     ------------------
!
      CLASS(HexMesh)    :: self
      CHARACTER(LEN=*)  :: fileName
!
!     ---------------
!     Local variables
!     ---------------
!
      INTEGER           :: fID
      INTEGER           :: no_of_bdryfaces
      
      no_of_bdryfaces = 0
      
      write(STD_OUT,'(/)')
      call Section_Header("Reading mesh")
      write(STD_OUT,'(/)')
      
      call SubSection_Header('Mesh file "' // trim(fileName) // '".')

      write(STD_OUT,'(30X,A,A28,I10)') "->" , "Number of nodes: " , size ( self % nodes )
      write(STD_OUT,'(30X,A,A28,I10)') "->" , "Number of elements: " , size ( self % elements )
      write(STD_OUT,'(30X,A,A28,I10)') "->" , "Number of faces: " , size ( self % faces )
   
      do fID = 1 , size ( self % faces )
         if ( self % faces(fID) % faceType .ne. HMESH_INTERIOR) then
            no_of_bdryfaces = no_of_bdryfaces + 1
         end if
      end do

      write(STD_OUT,'(30X,A,A28,I10)') "->" , "Number of boundary faces: " , no_of_bdryfaces

      END SUBROUTINE DescribeMesh     
!
!////////////////////////////////////////////////////////////////////////
! 
      SUBROUTINE WriteCoordFile(self,FileName)
         USE PhysicsStorage
         IMPLICIT NONE
!
!        -----------------------------------------------------------------
!        This subroutine writes a *.coo file containing all the mesh nodes
!        that can be used for eigenvalue analysis using the TAUev code
!        -----------------------------------------------------------------
!
         !--------------------------------------------------------
         CLASS(HexMesh)       :: self        !<  this mesh
         CHARACTER(len=*)     :: FileName    !<  ...
         !--------------------------------------------------------
         INTEGER              :: NumOfElem
         INTEGER              :: i, j, k, el, Nx, Ny, Nz, ndof, cooh
         !--------------------------------------------------------
          
         NumOfElem = SIZE(self % elements)
!
!        ------------------------------------------------------------------------
!        Determine the number of degrees of freedom
!           TODO: Move this to another place if needed in other parts of the code
!        ------------------------------------------------------------------------
!
         ndof = 0
         DO el = 1, NumOfElem
            Nx = self % elements(el) % Nxyz(1)
            Ny = self % elements(el) % Nxyz(2)
            Nz = self % elements(el) % Nxyz(3)
            ndof = ndof + (Nx + 1)*(Ny + 1)*(Nz + 1)*N_EQN
         END DO
         
         OPEN(newunit=cooh, file=FileName, action='WRITE')
         
         WRITE(cooh,*) ndof, ndim   ! defined in PhysicsStorage
         DO el = 1, NumOfElem
            Nx = self % elements(el) % Nxyz(1)
            Ny = self % elements(el) % Nxyz(2)
            Nz = self % elements(el) % Nxyz(3)
            DO k = 0, Nz
               DO j = 0, Ny
                  DO i = 0, Nx
                     WRITE(cooh,*) self % elements(el) % geom % x(1,i,j,k), &
                                   self % elements(el) % geom % x(2,i,j,k), &
                                   self % elements(el) % geom % x(3,i,j,k)
                  END DO
               END DO
            END DO
         END DO
         
         CLOSE(cooh)
         
      END SUBROUTINE WriteCoordFile
!
!////////////////////////////////////////////////////////////////////////
!
!        Set element connectivities
!        --------------------------
!
!////////////////////////////////////////////////////////////////////////
!
      subroutine HexMesh_SetConnectivities(self)
         implicit none
         class(HexMesh)       :: self
!
!        ---------------
!        Local variables
!        ---------------
!
         integer  :: fID, eL, eR, fL, fR
         

         do fID = 1, size(self % faces)
!
!           Gather involved elements
!           ------------------------
            eL = self % faces(fID) % elementIDs(1)
            eR = self % faces(fID) % elementIDs(2)
!
!           Cycle if the right element is zero (boundary face)
!           --------------------------------------------------
            if ( eR .eq. 0 ) cycle
!
!           Get element sides
!           -----------------
            fL = self % faces(fID) % elementSide(1)
            fR = self % faces(fID) % elementSide(2)
!
!           Fill the information with the connectivities
!           --------------------------------------------
            self % elements(eL) % Connection( fL ) % ElementIDs(1) = eR
            self % elements(eR) % Connection( fR ) % ElementIDs(1) = eL

         end do

      end subroutine HexMesh_SetConnectivities

      subroutine HexMesh_Export(self, fileName)
         use SolutionFile
         implicit none
         class(HexMesh),   intent(in)     :: self
         character(len=*), intent(in)     :: fileName
!
!        ---------------
!        Local variables
!        ---------------
!
         integer        :: fID, eID
         character(len=LINE_LENGTH)    :: meshName
         real(kind=RP), parameter      :: refs(NO_OF_SAVED_REFS) = 0.0_RP
         interface
            character(len=LINE_LENGTH) function RemovePath( inputLine )
               use SMConstants
               implicit none
               character(len=*)     :: inputLine
            end function RemovePath
      
            character(len=LINE_LENGTH) function getFileName( inputLine )
               use SMConstants
               implicit none
               character(len=*)     :: inputLine
            end function getFileName
         end interface

            
!
!        Create file: it will be contained in ./MESH
!        -------------------------------------------
         meshName = "./MESH/" // trim(removePath(getFileName(fileName))) // ".hmesh"
         fID = CreateNewSolutionFile( trim(meshName), MESH_FILE, self % no_of_elements, 0, 0.0_RP, refs)
!
!        Introduce all element nodal coordinates
!        ---------------------------------------
         do eID = 1, self % no_of_elements
            call writeArray(fID, self % elements(eID) % geom % x)
         end do
!
!        Close the file
!        --------------
         call CloseSolutionFile(fID)
         
      end subroutine HexMesh_Export

      subroutine HexMesh_SaveSolution(self, iter, time, name, saveGradients)
         use SolutionFile
         implicit none
         class(HexMesh),      intent(in)        :: self
         integer,             intent(in)        :: iter
         real(kind=RP),       intent(in)        :: time
         character(len=*),    intent(in)        :: name
         logical,             intent(in)        :: saveGradients
!
!        ---------------
!        Local variables
!        ---------------
!
         integer  :: fid, eID
         real(kind=RP)                    :: refs(NO_OF_SAVED_REFS) 
!
!        Gather reference quantities
!        ---------------------------
         refs(GAMMA_REF) = thermodynamics % gamma
         refs(RGAS_REF)  = thermodynamics % R
         refs(RHO_REF)   = refValues      % rho
         refs(V_REF)     = refValues      % V
         refs(T_REF)     = refValues      % T
         refs(MACH_REF)  = dimensionless  % Mach
!
!        Create new file
!        ---------------
         if ( saveGradients ) then
            fid = CreateNewSolutionFile(trim(name),SOLUTION_AND_GRADIENTS_FILE, self % no_of_elements, iter, time, refs)
         else
            fid = CreateNewSolutionFile(trim(name),SOLUTION_FILE, self % no_of_elements, iter, time, refs)
         end if
!
!        Write arrays
!        ------------
         do eID = 1, self % no_of_elements
            associate( e => self % elements(eID) )
            call writeArray(fid, e % storage % Q)
            if ( saveGradients ) then
               write(fid) e % storage % U_x
               write(fid) e % storage % U_y
               write(fid) e % storage % U_z
            end if
            end associate
         end do

      end subroutine HexMesh_SaveSolution

      subroutine HexMesh_SaveStatistics(self, iter, time, name)
         use SolutionFile
         implicit none
         class(HexMesh),      intent(in)        :: self
         integer,             intent(in)        :: iter
         real(kind=RP),       intent(in)        :: time
         character(len=*),    intent(in)        :: name
!
!        ---------------
!        Local variables
!        ---------------
!
         integer  :: fid, eID
         real(kind=RP)                    :: refs(NO_OF_SAVED_REFS) 
!
!        Gather reference quantities
!        ---------------------------
         refs(GAMMA_REF) = thermodynamics % gamma
         refs(RGAS_REF)  = thermodynamics % R
         refs(RHO_REF)   = refValues      % rho
         refs(V_REF)     = refValues      % V
         refs(T_REF)     = refValues      % T
         refs(MACH_REF)  = dimensionless  % Mach
!
!        Create new file
!        ---------------
         fid = CreateNewSolutionFile(trim(name),STATS_FILE, self % no_of_elements, iter, time, refs)
!
!        Write arrays
!        ------------
         do eID = 1, self % no_of_elements
            associate( e => self % elements(eID) )
            call writeArray(fid, e % storage % stats % data)
            end associate
         end do

      end subroutine HexMesh_SaveStatistics

      subroutine HexMesh_ResetStatistics(self)
         implicit none
         class(HexMesh)       :: self
!
!        ---------------
!        Local variables
!        ---------------
!
         integer     :: eID

         do eID = 1, self % no_of_elements
            self % elements(eID) % storage % stats % data = 0.0_RP
         end do

      end subroutine HexMesh_ResetStatistics

      subroutine HexMesh_LoadSolution( self, fileName, initial_iteration, initial_time ) 
         use SolutionFile
         IMPLICIT NONE
         CLASS(HexMesh)             :: self
         character(len=*)           :: fileName
         integer,       intent(out) :: initial_iteration
         real(kind=RP), intent(out) :: initial_time
         
!
!        ---------------
!        Local variables
!        ---------------
!
         INTEGER          :: fID, eID, fileType, no_of_elements, flag
         integer          :: Nxp1, Nyp1, Nzp1, no_of_eqs
         character(len=SOLFILE_STR_LEN)      :: rstName
!
!        Open the file
!        -------------
         open(newunit = fID, file=trim(fileName), status="old", action="read", form="unformatted")
!
!        Get the file title
!        ------------------
         read(fID) rstName
!
!        Get the file type
!        -----------------
         read(fID) fileType

         select case (fileType)
         case(MESH_FILE)
            print*, "The selected restart file is a mesh file"
            errorMessage(STD_OUT)
            stop

         case(SOLUTION_FILE)
         case(SOLUTION_AND_GRADIENTS_FILE)
         case(STATS_FILE)
            print*, "The selected restart file is a statistics file"
            errorMessage(STD_OUT)
            stop
         case default
            print*, "Unknown restart file format"
            errorMessage(STD_OUT)
            stop
         end select
!
!        Read the number of elements
!        ---------------------------
         read(fID) no_of_elements

         if ( no_of_elements .ne. size(self % elements) ) then
            write(STD_OUT,'(A,A)') "The number of elements stored in the restart file ", &
                                   "do not match that of the mesh file"
            errorMessage(STD_OUT)
            stop
         end if
!
!        Read the initial iteration and time
!        -----------------------------------
         read(fID) initial_iteration
         read(fID) initial_time          
!
!        Read the terminator indicator
!        -----------------------------
         read(fID) flag

         if ( flag .ne. BEGINNING_DATA ) then
            print*, "Beginning data flag was not found in the file."
            errorMessage(STD_OUT)
            stop
         end if
!
!        Read elements data
!        ------------------
         do eID = 1, size(self % elements)
            associate( e => self % elements(eID) )
            read(fID) Nxp1, Nyp1, Nzp1, no_of_eqs
            if (      ((Nxp1-1) .ne. e % Nxyz(1)) &
                 .or. ((Nyp1-1) .ne. e % Nxyz(2)) &
                 .or. ((Nzp1-1) .ne. e % Nxyz(3)) &
                 .or. (no_of_eqs .ne. NCONS )       ) then
               write(STD_OUT,'(A,I0,A)') "Error reading restart file: wrong dimension for element "&
                                           ,eID,"."

               write(STD_OUT,'(A,I0,A,I0,A,I0,A)') "Element dimensions: ", e % Nxyz(1), &
                                                                     " ,", e % Nxyz(2), &
                                                                     " ,", e % Nxyz(3), &
                                                                     "."
                                                                     
               write(STD_OUT,'(A,I0,A,I0,A,I0,A)') "Restart dimensions: ", Nxp1-1, &
                                                                     " ,", Nyp1-1, &
                                                                     " ,", Nzp1-1, &
                                                                     "."

               errorMessage(STD_OUT)
               stop
            end if

            read(fID) e % storage % Q 
!
!           Skip the gradients record if proceeds
!           -------------------------------------   
            if ( fileType .eq. SOLUTION_AND_GRADIENTS_FILE ) then
               read(fID)
               read(fID)
               read(fID)
            end if
            end associate
         end do

      END SUBROUTINE HexMesh_LoadSolution
! 
!//////////////////////////////////////////////////////////////////////// 
!
!        CONSTRUCT ZONES
!        ---------------
! 
!//////////////////////////////////////////////////////////////////////// 
! 
      subroutine HexMesh_ConstructZones( self )
      implicit none
      class(HexMesh)          :: self

      call ConstructZones ( self % faces , self % zones )

      end subroutine HexMesh_ConstructZones
!
!///////////////////////////////////////////////////////////////////////
!
END MODULE HexMeshClass
      

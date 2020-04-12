# -*- coding: utf-8 -*-
"""
Raytracing on unstructured triangular and tetrahedral meshes

"""

# distutils: language = c++

import numpy as np
cimport numpy as np
import scipy.sparse as sp

import vtk
from vtk.util import numpy_support

cdef extern from "verbose.h" namespace "ttcr" nogil:
    void setVerbose(int)

def set_verbose(v):
    """Set verbosity level for C++ code

    Parameters
    ----------
    v: int
        verbosity level
    """
    setVerbose(v)


cdef class Mesh3d:
    """class to perform raytracing with tetrahedral meshes

    Constructor:

    Mesh3d(nodes, tetra, nthreads, cell_slowness, method, gradient_method,
           tt_from_rp, interp_vel, eps, maxit, min_dist, n_secondary,
           n_tertiary, radius_tertiary)

        Parameters
        ----------
        nodes : np.ndarray, shape (nnodes, 3)
            node coordinates
        tetra : np.ndarray of int, shape (ntetra, 4)
            indices of nodes forming the tetrahedra
        nthreads : int
            number of threads for raytracing (default is 1)
        cell_slowness : bool
            slowness defined for cells (True) or nodes (False) (default is 1)
        method : string
            raytracing method (default is FSM)
                - 'FSM' : fast marching method
                - 'SPM' : shortest path method
                - 'DSPM' : dynamic shortest path
        gradient_method : int
            method to compute traveltime gradient (default is 1)
                - 0 : least-squares first-order
                - 1 : least-squares second-order
                - 2 : Averaging-Based method
        tt_from_rp : bool
            compute traveltimes from raypaths (SPM od DSPM) (default is 1)
        interp_vel : bool
            interpolate velocity instead of slowness at nodes (for
            cell_slowness == False or FSM) (defauls is False)
        eps : double
            convergence criterion (FSM) (default is 1e-15)
        maxit : int
            max number of sweeping iterations (FSM) (default is 20)
        min_dist : double
            tolerance for backward raytracing (default is 1e-5)
        n_secondary : int
            number of secondary nodes (DSPM) (default is 2)
        n_tertiary : int
            number of tertiary nodes (DSPM) (default is 2)
        radius_tertiary : double
            radius of sphere around source that includes tertiary nodes (DSPM)
            (default is 1)

    """
    cdef bool cell_slowness
    cdef size_t _nthreads
    cdef char method
    cdef bool tt_from_rp
    cdef bool interp_vel
    cdef double eps
    cdef int maxit
    cdef int gradient_method
    cdef double min_dist
    cdef uint32_t n_secondary
    cdef uint32_t n_tertiary
    cdef double radius_tertiary
    cdef vector[sxyz[double]] no
    cdef vector[tetrahedronElem[uint32_t]] tet
    cdef Grid3D[double, uint32_t]* grid

    def __cinit__(self, np.ndarray[np.double_t, ndim=2] nodes,
                  np.ndarray[np.int64_t, ndim=2] tetra,
                  size_t nthreads=1, bool cell_slowness=1,
                  str method='FSM', int gradient_method=1,
                  bool tt_from_rp=1, bool interp_vel=0,
                  double eps=1.e-15, int maxit=20, double min_dist=1.e-5,
                  uint32_t n_secondary=2, uint32_t n_tertiary=2,
                  double radius_tertiary=1.0):

        self.cell_slowness = cell_slowness
        self._nthreads = nthreads
        self.tt_from_rp = tt_from_rp
        self.interp_vel = interp_vel
        self.eps = eps
        self.maxit = maxit
        self.gradient_method = gradient_method
        self.min_dist = min_dist
        self.n_secondary = n_secondary
        self.n_tertiary = n_tertiary
        self.radius_tertiary = radius_tertiary

        cdef double source_radius = 0.0

        cdef int n
        for n in range(nodes.shape[0]):
            self.no.push_back(sxyz[double](nodes[n, 0],
                                           nodes[n, 1],
                                           nodes[n, 2]))
        for n in range(tetra.shape[0]):
            self.tet.push_back(tetrahedronElem[uint32_t](tetra[n, 0],
                                                         tetra[n, 1],
                                                         tetra[n, 2],
                                                         tetra[n, 3]))

        if cell_slowness:
            if method == 'FSM':
                self.method = b'f'
                self.grid = new Grid3Ducfs[double,uint32_t](self.no, self.tet,
                                                            eps, maxit,
                                                            gradient_method,
                                                            tt_from_rp,
                                                            min_dist, nthreads)
            elif method == 'SPM':
                self.method = b's'
                self.grid = new Grid3Ducsp[double,uint32_t](self.no, self.tet,
                                                            n_secondary,
                                                            tt_from_rp,
                                                            min_dist, nthreads)
            elif method == 'DSPM':
                self.method = b'd'
                self.grid = new Grid3Ducdsp[double,uint32_t](self.no, self.tet,
                                                             n_secondary,
                                                             n_tertiary,
                                                             source_radius,
                                                             gradient_method,
                                                             tt_from_rp,
                                                             min_dist,
                                                             radius_tertiary,
                                                             nthreads)

            else:
                raise ValueError('Method {0:s} undefined'.format(method))
        else:
            if method == 'FSM':
                self.method = b'f'
                self.grid = new Grid3Dunfs[double,uint32_t](self.no, self.tet,
                                                            eps, maxit,
                                                            gradient_method,
                                                            interp_vel,
                                                            tt_from_rp,
                                                            min_dist, nthreads)
            elif method == 'SPM':
                self.method = b's'
                self.grid = new Grid3Dunsp[double,uint32_t](self.no, self.tet,
                                                            n_secondary,
                                                            interp_vel,
                                                            tt_from_rp,
                                                            min_dist, nthreads)
            elif method == 'DSPM':
                self.method = b'd'
                self.grid = new Grid3Dundsp[double,uint32_t](self.no, self.tet,
                                                             n_secondary,
                                                             n_tertiary,
                                                             source_radius,
                                                             interp_vel,
                                                             gradient_method,
                                                             tt_from_rp,
                                                             min_dist,
                                                             radius_tertiary,
                                                             nthreads)
            else:
                raise ValueError('Method {0:s} undefined'.format(method))

    def __dealloc__(self):
        del self.grid

    def __reduce__(self):
        if self.method == b'f':
            method = 'FSM'
        elif self.method == b's':
            method = 'SPM'
        elif self.method == b'd':
            method = 'DSPM'

        nodes = np.ndarray((self.no.size(), 3))
        tetra = np.ndarray((self.tet.size(), 4), dtype=int)
        cdef int n
        cdef int nn
        for n in range(nodes.shape[0]):
            nodes[n, 0] = self.no[n].x
            nodes[n, 1] = self.no[n].y
            nodes[n, 2] = self.no[n].z
        for n in range(tetra.shape[0]):
            for nn in range(4):
                tetra[n, nn] = self.tet[n].i[nn]

        constructor_params = (nodes, tetra, method, self.cell_slowness,
                              self._nthreads, self.tt_from_rp, self.interp_vel,
                              self.eps, self.maxit, self.gradient_method,
                              self.min_dist, self.n_secondary, self.n_tertiary,
                              self.radius_tertiary)
        return (_rebuild3d, constructor_params)

    @property
    def nthreads(self):
        """int: number of threads for raytracing"""
        return self._nthreads

    @property
    def nparams(self):
        """int: total number of parameters for mesh"""
        if self.cell_slowness:
            return self.tet.size()
        else:
            return self.no.size()

    def get_number_of_nodes(self):
        """
        Returns
        -------
        int:
            number of nodes in grid
        """
        return self.no.size()

    def get_number_of_cells(self):
        """
        Returns
        -------
        int:
            number of cells in grid
        """
        return self.tet.size()

    def get_grid_traveltimes(self, thread_no=0):
        """
        get_grid_traveltimes(thread_no=0)

        Obtain traveltimes computed at primary grid nodes

        Parameters
        ----------
        thread_no : int
            thread used to computed traveltimes (default is 0)

        Returns
        -------
        tt: np ndarray, shape (nnodes,)
            traveltimes
        """
        if thread_no >= self._nthreads:
            raise ValueError('Thread number is larger than number of threads')
        cdef vector[double] tmp
        cdef int n
        self.grid.getTT(tmp, thread_no)
        tt = np.empty((tmp.size(),))
        for n in range(tmp.size()):
            tt[n] = tmp[n]
        return tt

    def set_slowness(self, slowness):
        """
        set_slowness(slowness)

        Assign slowness to grid

        Parameters
        ----------
        slowness : np ndarray, shape (nparams, )
        """
        if slowness.size != self.nparams:
            raise ValueError('Slowness vector has wrong size')

        if not slowness.flags['C_CONTIGUOUS']:
            slowness = np.ascontiguousarray(slowness)

        cdef vector[double] slown
        cdef int i
        for i in range(slowness.size):
            slown.push_back(slowness[i])
        self.grid.setSlowness(slown)

    def set_velocity(self, velocity):
        """
        set_velocity(velocity)

        Assign velocity to grid

        Parameters
        ----------
        velocity : np ndarray, shape (nparams, )
        """
        if velocity.size != self.nparams:
            raise ValueError('velocity vector has wrong size')

        if not velocity.flags['C_CONTIGUOUS']:
            velocity = np.ascontiguousarray(velocity)

        cdef vector[double] slown
        cdef int i
        for i in range(velocity.size):
            slown.push_back(1./velocity[i])
        self.grid.setSlowness(slown)

    def raytrace(self, source, rcv, slowness=None, thread_no=None,
                 aggregate_src=False, return_rays=False):
        """
        raytrace(source, rcv, slowness=None, thread_no=None,
              aggregate_src=False, return_rays=False) -> tt, rays

        Perform raytracing

        Parameters
        ----------
        source : 2D np.ndarray with 3, 4 or 5 columns
            see notes below
        rcv : 2D np.ndarray with 3 columns
            Columns correspond to x, y and z coordinates
        slowness : np ndarray, shape (nx, ny, nz) (None by default)
            slowness at grid nodes or cells (depending on cell_slowness)
            slowness may also have been flattened (with default 'C' order)
            if None, slowness must have been assigned previously
        thread_no : int (None by default)
            Perform calculations in thread number "thread_no"
            if None, attempt to run in parallel if warranted by number of
            sources and value of nthreads in constructor
        aggregate_src : bool (False by default)
            if True, all source coordinates belong to a single event
        return_rays : bool (False by default)
            Return raypaths

        Returns
        -------
        tt : np.ndarray
            travel times for the appropriate source-rcv  (see Notes below)
        rays : :obj:`list` of :obj:`np.ndarray`
            Coordinates of segments forming raypaths (if return_rays is True)

        Notes
        -----
        If source has 3 columns:
            - Columns correspond to x, y and z coordinates
            - Origin time (t0) is 0 for all points
        If source has 4 columns:
            - 1st column corresponds to origin times
            - 2nd, 3rd & 4th columns correspond to x, y and z coordinates
        If source has 5 columns:
            - 1st column corresponds to event ID
            - 2nd column corresponds to origin times
            - 3rd, 4th & 5th columns correspond to x, y and z coordinates

        For the latter case (5 columns), source and rcv should contain the same
        number of rows, each row corresponding to a source-receiver pair.
        For the 2 other cases, source and rcv can contain the same number of
        rows, each row corresponding to a source-receiver pair, or the number
        of rows may differ if aggregate_src is True or if all rows in source
        are identical.
        """

        # check input data consistency

        if source.ndim != 2 or rcv.ndim != 2:
            raise ValueError('source and rcv should be 2D arrays')

        if self.method == b'd' and aggregate_src:
            raise ValueError('Cannot aggregate source with DSPM raytracing')

        evID = None
        if source.shape[1] == 5:
            src = source[:,2:5]
            t0 = source[:,1]
            evID = source[:,0]
            eid = np.sort(np.unique(evID))
            nTx = len(eid)
        elif source.shape[1] == 3:
            src = source
            Tx = np.unique(source, axis=0)
            t0 = np.zeros((Tx.shape[0], 1))
            nTx = Tx.shape[0]
        elif source.shape[1] == 4:
            src = source[:,1:4]
            tmp = np.unique(source, axis=0)
            nTx = tmp.shape[0]
            Tx = tmp[:,1:4]
            t0 = tmp[:,0]
        else:
            raise ValueError('source should be either nsrc x 3, 4 or 5')

        if src.shape[1] != 3 or rcv.shape[1] != 3:
            raise ValueError('src and rcv should be ndata x 3')

        if self.is_outside(src):
            raise ValueError('Source point outside grid')

        if self.is_outside(rcv):
            raise ValueError('Receiver outside grid')

        if slowness is not None:
            self.set_slowness(slowness)

        cdef vector[vector[sxyz[double]]] vTx
        cdef vector[vector[sxyz[double]]] vRx
        cdef vector[vector[double]] vt0
        cdef vector[vector[double]] vtt

        cdef vector[vector[vector[sxyz[double]]]] r_data
        cdef size_t thread_nb

        cdef int i, n, n2, nt

        vTx.resize(nTx)
        vRx.resize(nTx)
        vt0.resize(nTx)
        vtt.resize(nTx)
        if return_rays:
            r_data.resize(nTx)

        iRx = []
        if evID is None:
            if nTx == 1:
                vTx[0].push_back(sxyz[double](src[0,0], src[0,1], src[0,2]))
                for r in rcv:
                    vRx[0].push_back(sxyz[double](r[0], r[1], r[2]))
                vt0[0].push_back(t0[0])
                vtt[0].resize(rcv.shape[0])
                iRx.append(np.arange(rcv.shape[0]))
            elif aggregate_src:
                for t in Tx:
                    vTx[0].push_back(sxyz[double](t[0], t[1], t[2]))
                for t in t0:
                    vt0[0].push_back(t)
                for r in rcv:
                    vRx[0].push_back(sxyz[double](r[0], r[1], r[2]))
                vtt[0].resize(rcv.shape[0])
                nTx = 1
                iRx.append(np.arange(rcv.shape[0]))
            else:
                if src.shape != rcv.shape:
                    raise ValueError('src and rcv should be of equal size')

                for n in range(nTx):
                    ind = np.sum(Tx[n,:] == src, axis=1) == 3
                    iRx.append(np.nonzero(ind)[0])
                    vTx[n].push_back(sxyz[double](Tx[n,0], Tx[n,1], Tx[n,2]))
                    vt0[n].push_back(t0[n])
                    for r in rcv[ind,:]:
                        vRx[n].push_back(sxyz[double](r[0], r[1], r[2]))
                    vtt[n].resize(vRx[n].size())
        else:
            if src.shape != rcv.shape:
                raise ValueError('src and rcv should be of equal size')

            i0 = 0
            for n in range(nTx):
                for nn in range(evID.size):
                    if eid[n] == evID[nn]:
                        i0 = nn
                        break
                vTx[n].push_back(sxyz[double](src[i0,0], src[i0,1], src[i0,2]))
                vt0[n].push_back(t0[i0])

            for i in eid:
                ii = evID == i
                iRx.append(np.nonzero(ii)[0])

            for n in range(nTx):
                for r in rcv[iRx[n],:]:
                    vRx[n].push_back(sxyz[double](r[0], r[1], r[2]))
                vtt[n].resize(vRx[n].size())

        tt = np.zeros((rcv.shape[0],))
        if nTx < self._nthreads or self._nthreads == 1:
            if return_rays==False:
                for n in range(nTx):
                    self.grid.raytrace(vTx[n], vt0[n], vRx[n], vtt[n], 0)
            else:
                for n in range(nTx):
                    self.grid.raytrace(vTx[n], vt0[n], vRx[n], vtt[n], r_data[n], 0)

        elif thread_no is not None:
            # we should be here for just one event
            assert nTx == 1
            thread_nb = thread_no

            if return_rays:
                self.grid.raytrace(vTx[0], vt0[0], vRx[0], vtt[0], r_data[0], thread_nb)
                for nt in range(vtt[0].size()):
                    tt[nt] = vtt[0][nt]
                rays = []
                for n2 in range(vRx.size()):
                    r = np.empty((r_data[0][n2].size(), 3))
                    for nn in range(r_data[0][n2].size()):
                        r[nn, 0] = r_data[0][n2][nn].x
                        r[nn, 1] = r_data[0][n2][nn].y
                        r[nn, 2] = r_data[0][n2][nn].z
                    rays.append(r)
                return tt, rays

            else:
                self.grid.raytrace(vTx[0], vt0[0], vRx[0], vtt[0], thread_nb)
                for nt in range(vtt[0].size()):
                    tt[nt] = vtt[0][nt]
                return tt

        else:
            if return_rays==False:
                self.grid.raytrace(vTx, vt0, vRx, vtt)
            else:
                self.grid.raytrace(vTx, vt0, vRx, vtt, r_data)

        for n in range(nTx):
            for nt in range(vtt[n].size()):
                tt[iRx[n][nt]] = vtt[n][nt]

        if return_rays:
            rays = [ [0.0] for n in range(rcv.shape[0])]
            for n in range(nTx):
                r = [ [0.0] for i in range(vRx[n].size())]
                for n2 in range(vRx[n].size()):
                    r[n2] = np.empty((r_data[n][n2].size(), 3))
                    for nn in range(r_data[n][n2].size()):
                        r[n2][nn, 0] = r_data[n][n2][nn].x
                        r[n2][nn, 1] = r_data[n][n2][nn].y
                        r[n2][nn, 2] = r_data[n][n2][nn].z
                for nt in range(vtt[n].size()):
                    rays[iRx[n][nt]] = r[nt]

        if return_rays==False:
            return tt
        else:
            return tt, rays

    def to_vtk(self, fields, filename):
        """
        to_vtk(fields, filename)

        Save mesh variables and/or raypaths to VTK format

        Parameters
        ----------
        fields: dict
            dict of variables to save to file. Variables should be np.ndarray of
            size equal to either the number of nodes of the number of cells of
            the mesh, or a list of raypath coordinates.
        filename: str
            Name of file without extension for saving (extension vtu will be
            added).  Raypaths are saved in separate files, and filename will
            be appended by the dict key and have a vtp extension.

        Notes
        -----
        VTK files can be visualized with Paraview (https://www.paraview.org)
        """
        cdef int n, nn
        ugrid = vtk.vtkUnstructuredGrid()
        tPts = vtk.vtkPoints()
        tPts.SetNumberOfPoints(self.no.size())
        for n in range(self.no.size()):
            tPts.InsertPoint(n, self.no[n].x, self.no[n].y, self.no[n].z)
        ugrid.SetPoints(tPts)
        tet = vtk.vtkTetra
        for n in range(self.tet.size()):
            for nn in range(4):
                tet.GetPointIds().SetId(nn, self.tet[n].i[nn])
            ugrid.InsertNextCell(tet.GetCellType(), tet.GetPointIds())

        save_grid = False
        for fn in fields:
            data = fields[fn]

            if isinstance(data, list):
                self._save_raypaths(data, filename+'_'+fn+'.vtp')
            else:
                save_grid = True
                scalar = vtk.vtkDoubleArray()
                scalar.SetName(fn)
                scalar.SetNumberOfComponents(1)
                scalar.SetNumberOfTuples(data.size)
                if data.size == self.get_number_of_nodes():
                    for n in range(data.size):
                        scalar.SetTuple1(n, data[n])
                    ugrid.GetPointData().AddArray(scalar)
                elif data.size == self.get_number_of_cells():
                    for n in range(data.size):
                        scalar.SetTuple1(n, data[n])
                    ugrid.GetCellData().AddArray(scalar)
                else:
                    raise ValueError('Field {0:s} has incorrect size'.format(fn))

        if save_grid:
            writer = vtk.vtkXMLUnstructuredGridWriter()
            writer.SetFileName(filename+'.vtu')
            writer.SetInputData(ugrid)
            writer.SetDataModeToBinary()
            writer.Update()

    def  _save_raypaths(self, rays, filename):
        polydata = vtk.vtkPolyData()
        cellarray = vtk.vtkCellArray()
        pts = vtk.vtkPoints()
        npts = 0
        for n in range(len(rays)):
            npts += rays[n].shape[0]
        pts.SetNumberOfPoints(npts)
        npts = 0
        for n in range(len(rays)):
            for p in range(rays[n].shape[0]):
                pts.InsertPoint(npts, rays[n][p, 0], rays[n][p, 1], rays[n][p, 2])
                npts += 1
        polydata.SetPoints(pts)
        npts = 0
        for n in range(len(rays)):
            line = vtk.vtkPolyLine()
            line.GetPointIds().SetNumberOfIds(rays[n].shape[0])
            for p in range(rays[n].shape[0]):
                line.GetPointIds().SetId(p, npts)
                npts += 1
            cellarray.InsertNextCell(line)
        polydata.SetLines(cellarray)
        writer = vtk.vtkXMLPolyDataWriter()
        writer.SetFileName(filename)
        writer.SetInputData(polydata)
        writer.SetDataModeToBinary()
        writer.Update()


    @staticmethod
    def builder(filename, size_t nthreads=1, bool cell_slowness=1,
                str method='FSM', int gradient_method=1,
                bool tt_from_rp=1, bool interp_vel=0,
                double eps=1.e-15, int maxit=20, double min_dist=1.e-5,
                uint32_t n_secondary=2, uint32_t n_tertiary=2,
                double radius_tertiary=1.0):
        """
        builder(filename, nthreads, cell_slowness, method, gradient_method,
                tt_from_rp, interp_vel, eps, maxit, min_dist, n_secondary,
                n_tertiary, radius_tertiary)

        Build instance of Mesh3d from VTK file

        Parameters
        ----------
        filename : str
            Name of file holding a vtkUnstructuredGrid.
            The grid must have point or cell attribute named either
            'Slowness', 'slowness', 'Velocity', 'velocity', or
            'P-wave velocity'.  All cells must be of type vtkTetra
        Other parameters are defined in Constructor

        Returns
        -------
        mesh: :obj:`Mesh3d`
            mesh instance
        """

        cdef int n, nn
        reader = vtk.vtkXMLUnstructuredGridReader()
        reader.SetFileName(filename)
        reader.Update()

        data = reader.GetOutput()
        nodes = numpy_support.vtk_to_numpy(data.GetPoints().GetData())
        for n in range(data.GetNumberOfCells()):
            if data.GetCellType(n) != vtk.VTK_TETRA:
                raise ValueError('{0:s} should only contain tetrahedra')
        tet = np.ndarray((data.GetNumberOfCells(), 4))
        for n in range(data.GetNumberOfCells()):
            for nn in range(4):
                tet[n, nn] = data.GetCell(n).GetPointIds().GetId(nn)

        names = ('Slowness', 'slowness', 'Velocity', 'velocity',
                 'P-wave velocity')
        for name in names:
            if data.GetPointData().HasArray(name):
                cell_slowness = 0
                data = numpy_support.vtk_to_numpy(data.GetPointData().GetArray(name))
                break
            if data.GetCellData().HasArray(name):
                cell_slowness = 1
                data = numpy_support.vtk_to_numpy(data.GetCellData().GetArray(name))
                break
        else:
            raise ValueError('File should contain slowness or velocity data')

        if 'lowness' in name:
            slowness = data
        else:
            slowness = 1.0 / data

        m = Mesh3d(nodes, tet, nthreads, cell_slowness, method, gradient_method,
                   tt_from_rp, interp_vel, eps, maxit, min_dist, n_secondary,
                   n_tertiary, radius_tertiary)
        m.set_slowness(slowness)
        return m


def _rebuild3d(constructor_params):
    (nodes, tetra, method, cell_slowness, nthreads, tt_from_rp, interp_vel, eps,
     maxit, gradient_method, min_dist, n_secondary, n_tertiary,
     radius_tertiary) = constructor_params

    g = Mesh3d(nodes, tetra, nthreads, cell_slowness, method, gradient_method,
               tt_from_rp, interp_vel, eps, maxit, min_dist, n_secondary,
               n_tertiary, radius_tertiary)
    return g